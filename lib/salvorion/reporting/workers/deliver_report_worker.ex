defmodule Salvorion.Reporting.Workers.DeliverReportWorker do
  @moduledoc """
  Sends one recipient's copy of a generated report (FR-REP-03), then -
  once its own delivery reaches a terminal state (`sent` or `failed`,
  never while Oban is still retrying a transient failure) - checks
  whether every `ReportDelivery` for the run is now terminal, and if so
  finishes the activation's lifecycle (`Reporting.finish_run_if_complete/1`,
  which calls `Activations.mark_activation_reported/1`).

  `Reporting.get_or_create_delivery/2`'s unique-index-backed lookup
  means a retried attempt reuses the same `ReportDelivery` row rather
  than creating a second one for the same recipient.
  """
  use Oban.Worker, queue: :reports, max_attempts: 5

  require Logger

  alias Salvorion.Activations
  alias Salvorion.Mailer
  alias Salvorion.Reporting
  alias Salvorion.Reporting.Email

  @impl Oban.Worker
  def perform(
        %Oban.Job{args: %{"report_run_id" => run_id, "report_recipient_id" => recipient_id}} =
          job
      ) do
    {:ok, delivery} = Reporting.get_or_create_delivery(run_id, recipient_id)

    run = Reporting.get_report_run!(run_id)
    recipient = Reporting.get_report_recipient!(recipient_id)
    activation = Activations.get_activation!(run.activation_id)

    recipient
    |> Email.report_email(run, activation)
    |> Mailer.deliver()
    |> handle_result(delivery, run_id, job)
  end

  defp handle_result({:ok, _email}, delivery, run_id, _job) do
    {:ok, _delivery} = Reporting.mark_delivery_sent(delivery)
    Reporting.finish_run_if_complete(run_id)
    :ok
  end

  defp handle_result({:error, reason}, delivery, run_id, job) do
    if job.attempt >= job.max_attempts do
      Logger.error("report delivery exhausted retries for run #{run_id}: #{inspect(reason)}")
      {:ok, _delivery} = Reporting.mark_delivery_failed(delivery, reason)
      Reporting.finish_run_if_complete(run_id)
    end

    {:error, reason}
  end
end
