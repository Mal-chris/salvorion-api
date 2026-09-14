defmodule Salvorion.Reporting.Workers.GenerateReportWorker do
  @moduledoc """
  Renders and stores the PDF report for a closed activation (FR-REP-01,
  FR-REP-03; Document 08 section 4), then enqueues one
  `DeliverReportWorker` per currently-active `ReportRecipient` - or, if
  there are none, finishes the activation's lifecycle immediately
  (Document 09 section 5, branch F).

  Given only an `activation_id` (as the task asked), `perform/1` creates
  a fresh `ReportRun` on the job's first attempt and, on a retried
  attempt, continues with whichever `"pending"` run the first attempt
  already created (`Reporting.get_pending_report_run/1`) rather than
  creating a second one - so a transient Gotenberg failure and its retry
  leave exactly one `ReportRun` row behind, not an orphaned `"pending"`
  one plus whatever the retry produced. Oban's own retries handle
  transient failures; only on the job's last attempt is the run marked
  `"failed"`, so a report that could never be generated stays visible in
  history rather than silently disappearing.
  """
  use Oban.Worker, queue: :reports, max_attempts: 5

  require Logger

  alias Salvorion.Activations
  alias Salvorion.Reporting
  alias Salvorion.Reporting.Workers.DeliverReportWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activation_id" => activation_id}} = job) do
    activation = Activations.get_activation!(activation_id)
    {:ok, run} = get_or_create_run(activation_id, job.attempt)

    with {:ok, pdf} <- Reporting.render_report_pdf(activation) do
      path = Reporting.report_pdf_path(activation_id, run.id)
      File.write!(path, pdf)
      {:ok, run} = Reporting.mark_report_generated(run, path)

      enqueue_deliveries(run)
    else
      {:error, reason} ->
        if job.attempt >= job.max_attempts do
          Logger.error(
            "report generation exhausted retries for #{activation_id}: #{inspect(reason)}"
          )

          {:ok, _run} = Reporting.mark_report_failed(run, reason)
        end

        {:error, reason}
    end
  end

  defp get_or_create_run(activation_id, 1), do: Reporting.create_report_run(activation_id)

  defp get_or_create_run(activation_id, _attempt) do
    case Reporting.get_pending_report_run(activation_id) do
      nil -> Reporting.create_report_run(activation_id)
      run -> {:ok, run}
    end
  end

  defp enqueue_deliveries(run) do
    case Reporting.list_report_recipients(active_only: true) do
      [] ->
        {:ok, _run} = Reporting.mark_report_no_recipients(run)

        run.activation_id
        |> Activations.get_activation!()
        |> Activations.mark_activation_reported()
        |> case do
          {:ok, _activation} -> :ok
          {:error, _changeset} -> :ok
        end

      recipients ->
        Enum.each(recipients, fn recipient ->
          # The pending ReportDelivery row is created here, upfront, for
          # every recipient this run was actually generated for - not
          # lazily inside DeliverReportWorker - so
          # Reporting.finish_run_if_complete/1's "any delivery still
          # pending?" check has a complete, accurate set to check against
          # from the moment generation succeeds, rather than only seeing
          # whichever deliveries happen to have already executed.
          {:ok, _delivery} = Reporting.get_or_create_delivery(run.id, recipient.id)

          {:ok, _job} =
            %{report_run_id: run.id, report_recipient_id: recipient.id}
            |> DeliverReportWorker.new()
            |> Oban.insert()
        end)

        :ok
    end
  end
end
