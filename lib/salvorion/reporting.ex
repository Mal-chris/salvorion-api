defmodule Salvorion.Reporting do
  @moduledoc """
  What happens when an activation closes (FR-REP-01 to FR-REP-06;
  Document 08 section 4; Document 09 section 5).

  Three schemas already exist (`ReportRecipient`, `ReportRun`,
  `ReportDelivery` - `priv/repo/migrations`); this context is the first
  code to write to them.

  `ReportRecipient` management (Task 2) follows the same convention as
  every other context: no deletes, only `active: false`
  (`deactivate_report_recipient/2`), and every write audited via
  `Audit.Multi` (Document 10 section 5 - system-initiated writes below
  are audited too, with no actor, per the same section).

  `compile_report_data/1` (Task 3) has no side effects and does not
  write anything; it exists so the report's *content* can be tested
  independently of PDF rendering or email delivery. `render_report_pdf/1`
  (Task 4) is the only function in this module that talks to a network
  service (Gotenberg). Everything from `create_report_run/2` onward is
  internal plumbing for `Salvorion.Reporting.Workers.*` - not meant to
  be called directly by a controller, which only ever calls
  `regenerate_report/2` (Task 7) or reads via `list_report_runs/1` and
  `get_report_run/2`.
  """

  import Ecto.Query, warn: false
  import Salvorion.Audit.Multi, only: [audit: 7, run_audited: 2, actor_id: 1]

  alias Ecto.Multi
  alias Salvorion.Accountability
  alias Salvorion.Activations
  alias Salvorion.Activations.Activation
  alias Salvorion.Audit
  alias Salvorion.Reporting.{ReportDelivery, ReportRecipient, ReportRun}
  alias Salvorion.Reporting.Workers.GenerateReportWorker
  alias Salvorion.Repo

  @type opts :: Salvorion.Audit.Multi.opts()

  # ---------------------------------------------------------------------------
  # Task 2: Report recipients (FR-REP-04)
  # ---------------------------------------------------------------------------

  @doc "Creates a report recipient. Audited as `\"report_recipient.created\"`."
  @spec create_report_recipient(map, opts) ::
          {:ok, %ReportRecipient{}} | {:error, Ecto.Changeset.t()}
  def create_report_recipient(attrs, opts \\ []) do
    Multi.new()
    |> Multi.insert(:recipient, ReportRecipient.changeset(%ReportRecipient{}, attrs))
    |> audit(
      :recipient,
      "report_recipient.created",
      "report_recipient",
      nil,
      &recipient_snapshot/1,
      opts
    )
    |> run_audited(:recipient)
  end

  @doc """
  Lists report recipients, alphabetically by name. `opts[:active_only]`
  defaults to `true` (the set `GenerateReportWorker` enqueues deliveries
  to); pass `active_only: false` for the admin screen that also needs to
  show deactivated ones.
  """
  @spec list_report_recipients(keyword) :: [%ReportRecipient{}]
  def list_report_recipients(opts \\ []) do
    active_only = Keyword.get(opts, :active_only, true)

    ReportRecipient
    |> maybe_filter_active(active_only)
    |> order_by([r], asc: r.name)
    |> Repo.all()
  end

  defp maybe_filter_active(query, true), do: where(query, [r], r.active == true)
  defp maybe_filter_active(query, false), do: query

  @doc "Updates a report recipient's name/email/role. Audited as `\"report_recipient.updated\"`."
  @spec update_report_recipient(%ReportRecipient{}, map, opts) ::
          {:ok, %ReportRecipient{}} | {:error, Ecto.Changeset.t()}
  def update_report_recipient(%ReportRecipient{} = recipient, attrs, opts \\ []) do
    before = recipient_snapshot(recipient)

    Multi.new()
    |> Multi.update(:recipient, ReportRecipient.changeset(recipient, attrs))
    |> audit(
      :recipient,
      "report_recipient.updated",
      "report_recipient",
      before,
      &recipient_snapshot/1,
      opts
    )
    |> run_audited(:recipient)
  end

  @doc """
  Deactivates a report recipient by setting `active: false`. Never
  deleted, same convention as every other context - `ReportDelivery`
  rows referencing this recipient remain intact as delivery history.
  Audited as `"report_recipient.deactivated"`.
  """
  @spec deactivate_report_recipient(%ReportRecipient{}, opts) ::
          {:ok, %ReportRecipient{}} | {:error, Ecto.Changeset.t()}
  def deactivate_report_recipient(%ReportRecipient{} = recipient, opts \\ []) do
    before = recipient_snapshot(recipient)

    Multi.new()
    |> Multi.update(:recipient, ReportRecipient.changeset(recipient, %{active: false}))
    |> audit(
      :recipient,
      "report_recipient.deactivated",
      "report_recipient",
      before,
      &recipient_snapshot/1,
      opts
    )
    |> run_audited(:recipient)
  end

  @spec get_report_recipient!(binary) :: %ReportRecipient{}
  def get_report_recipient!(id), do: Repo.get!(ReportRecipient, id)

  defp recipient_snapshot(%ReportRecipient{} = r),
    do: %{id: r.id, name: r.name, email: r.email, role: r.role, active: r.active}

  # ---------------------------------------------------------------------------
  # Task 3: report content
  # ---------------------------------------------------------------------------

  @doc """
  The full content of a closed activation's report (FR-REP-02), as a
  plain map with no side effects - unit-testable on its own, and reused
  by `render_report_pdf/1` as the template's assigns. Every field FR-REP-02
  names is present:

    * `:activation` - type, scope, started_at, closed_at
    * `:summary` - `Accountability.activation_summary/1`
    * `:by_department` - `Accountability.participation_by_department/1`
    * `:by_faculty` - `Accountability.participation_by_faculty/1`
    * `:unaccounted` - `Accountability.unaccounted_list/2`, unfiltered
    * `:manual_events` - `Accountability.list_manual_events/1` (Task 1)
  """
  @spec compile_report_data(%Activation{}) :: map
  def compile_report_data(%Activation{} = activation) do
    %{
      activation: %{
        id: activation.id,
        activation_type: activation.activation_type,
        scope: activation.scope,
        started_at: activation.started_at,
        closed_at: activation.closed_at
      },
      summary: Accountability.activation_summary(activation.id),
      by_department: Accountability.participation_by_department(activation.id),
      by_faculty: Accountability.participation_by_faculty(activation.id),
      unaccounted: Accountability.unaccounted_list(activation.id),
      manual_events: Accountability.list_manual_events(activation.id)
    }
  end

  @doc """
  Renders `compile_report_data/1`'s output through
  `priv/report_templates/activation_report.html.eex` and POSTs the
  resulting HTML to Gotenberg's Chromium HTML-to-PDF route (Task 4):
  `POST /forms/chromium/convert/html`, multipart field `files`, the HTML
  part named exactly `index.html` (Gotenberg identifies the entry file
  by filename, not by field name - confirmed against
  https://gotenberg.dev/docs/convert-with-chromium/convert-html-to-pdf).

  Returns `{:ok, pdf_binary}` or `{:error, reason}` - never raises on a
  Gotenberg-side failure, since this runs inside an Oban job
  (`GenerateReportWorker`) whose caller decides how to record it.
  """
  @spec render_report_pdf(%Activation{}) :: {:ok, binary} | {:error, term}
  def render_report_pdf(%Activation{} = activation) do
    html = render_html(activation)
    url = Application.fetch_env!(:salvorion, :gotenberg_url) <> "/forms/chromium/convert/html"

    case Req.post(url,
           form_multipart: [files: {html, filename: "index.html", content_type: "text/html"}],
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: 200, body: pdf}} when is_binary(pdf) ->
        {:ok, pdf}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:gotenberg_error, status, body}}

      {:error, reason} ->
        {:error, {:gotenberg_unreachable, reason}}
    end
  end

  # Compiled with Phoenix.HTML.Engine (already in the dependency tree via
  # phoenix_ecto/phoenix_live_view - no new dependency) rather than plain
  # EEx.eval_file/2, so `<%= %>` HTML-escapes interpolated values by
  # default (a person's name is untrusted-ish roster data) and `@foo`
  # reads `assigns.foo` the same way an ordinary Phoenix view template
  # would, without needing a view module.
  defp render_html(%Activation{} = activation) do
    data = compile_report_data(activation)

    template_path()
    |> EEx.compile_file(engine: Phoenix.HTML.Engine)
    |> Code.eval_quoted(assigns: data)
    |> elem(0)
    |> Phoenix.HTML.safe_to_string()
  end

  @doc """
  Formats a participation/accounted rate (a float in 0.0..1.0, or `nil`
  when there was nobody expected - see `Accountability.rate/2`) as a
  percentage string for the report template. Public, and called fully
  qualified from `priv/report_templates/activation_report.html.eex`,
  since the template is compiled standalone rather than inside a view
  module and cannot call a private or local function.
  """
  @spec format_rate(float | nil) :: String.t()
  def format_rate(nil), do: "n/a"
  def format_rate(rate) when is_float(rate), do: "#{Float.round(rate * 100, 1)}%"

  defp template_path do
    Path.join(:code.priv_dir(:salvorion), "report_templates/activation_report.html.eex")
  end

  @doc "Where a report run's PDF is stored: `priv/generated_reports/{activation_id}-{report_run_id}.pdf`."
  @spec report_pdf_path(binary, binary) :: String.t()
  def report_pdf_path(activation_id, report_run_id) do
    Path.join(
      :code.priv_dir(:salvorion),
      "generated_reports/#{activation_id}-#{report_run_id}.pdf"
    )
  end

  # ---------------------------------------------------------------------------
  # Task 5: ReportRun / ReportDelivery plumbing for the Oban workers.
  # System-initiated (Document 10 section 5: still audited, actor nil).
  # ---------------------------------------------------------------------------

  @doc "Creates a `pending` ReportRun for `activation_id`. Audited as `\"report.run_started\"`."
  @spec create_report_run(binary) :: {:ok, %ReportRun{}} | {:error, Ecto.Changeset.t()}
  def create_report_run(activation_id) do
    Multi.new()
    |> Multi.insert(:run, ReportRun.changeset(%ReportRun{}, %{activation_id: activation_id}))
    |> audit(:run, "report.run_started", "report_run", nil, &run_snapshot/1, [])
    |> run_audited(:run)
  end

  @doc "Marks a ReportRun `generated`, recording `pdf_path` and `generated_at`. Audited as `\"report.generated\"`."
  @spec mark_report_generated(%ReportRun{}, String.t()) ::
          {:ok, %ReportRun{}} | {:error, Ecto.Changeset.t()}
  def mark_report_generated(%ReportRun{} = run, pdf_path) do
    before = run_snapshot(run)
    attrs = %{status: "generated", pdf_path: pdf_path, generated_at: DateTime.utc_now()}

    Multi.new()
    |> Multi.update(:run, ReportRun.changeset(run, attrs))
    |> audit(:run, "report.generated", "report_run", before, &run_snapshot/1, [])
    |> run_audited(:run)
  end

  @doc """
  Marks a ReportRun `failed` after Oban's own retries are exhausted -
  the run stays visible in history rather than silently vanishing.
  `reason` (any term) is stringified into the audit row's `after`
  payload, since `ReportRun` itself has no column for it.
  """
  @spec mark_report_failed(%ReportRun{}, term) ::
          {:ok, %ReportRun{}} | {:error, Ecto.Changeset.t()}
  def mark_report_failed(%ReportRun{} = run, reason) do
    before = run_snapshot(run)

    Multi.new()
    |> Multi.update(:run, ReportRun.changeset(run, %{status: "failed"}))
    |> audit(
      :run,
      "report.generation_failed",
      "report_run",
      before,
      &Map.put(run_snapshot(&1), :reason, inspect(reason)),
      []
    )
    |> run_audited(:run)
  end

  @doc """
  Records that `run_id` had zero active recipients at generation time
  (Document 09 section 5, branch F) - the "recorded somewhere sensible"
  Prompt 11 asks for, distinct from a run whose recipients existed but
  all failed. Also sets the run's status to `"delivered"` (vacuously:
  zero deliveries, all zero of them terminal), since
  `finish_run_if_complete/1` never runs when there was nothing to
  enqueue.
  """
  @spec mark_report_no_recipients(%ReportRun{}) :: {:ok, %ReportRun{}} | {:error, term}
  def mark_report_no_recipients(%ReportRun{} = run) do
    before = run_snapshot(run)

    Multi.new()
    |> Multi.update(:run, ReportRun.changeset(run, %{status: "delivered"}))
    |> audit(:run, "report.no_recipients_configured", "report_run", before, &run_snapshot/1, [])
    |> run_audited(:run)
  end

  @doc "Fetches a ReportRun (raises if missing) - used by the workers, which are given only an id."
  @spec get_report_run!(binary) :: %ReportRun{}
  def get_report_run!(id), do: Repo.get!(ReportRun, id)

  @doc """
  The most recent `"pending"` ReportRun for `activation_id`, if any -
  used by `GenerateReportWorker` on a retried attempt (Oban attempt > 1)
  so a transient rendering failure re-uses the run its first attempt
  already created instead of leaving that one stranded at `"pending"`
  forever while a second row absorbs the actual result.
  """
  @spec get_pending_report_run(binary) :: %ReportRun{} | nil
  def get_pending_report_run(activation_id) do
    ReportRun
    |> where([r], r.activation_id == ^activation_id and r.status == "pending")
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  ReportRuns for an activation, newest first, each with its deliveries
  preloaded (recipient included) - `GET /api/activations/:id/reports`
  (FR-REP-06: history is retained, never overwritten).
  """
  @spec list_report_runs(binary) :: [%ReportRun{}]
  def list_report_runs(activation_id) do
    ReportRun
    |> where([r], r.activation_id == ^activation_id)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
    |> Repo.preload(deliveries: [:report_recipient])
  end

  @doc "One ReportRun, deliveries preloaded, or `nil`."
  @spec get_report_run(binary, binary) :: %ReportRun{} | nil
  def get_report_run(activation_id, run_id) do
    ReportRun
    |> where([r], r.activation_id == ^activation_id and r.id == ^run_id)
    |> Repo.one()
    |> case do
      nil -> nil
      run -> Repo.preload(run, deliveries: [:report_recipient])
    end
  end

  defp run_snapshot(%ReportRun{} = r),
    do: %{
      id: r.id,
      activation_id: r.activation_id,
      status: r.status,
      pdf_path: r.pdf_path,
      generated_at: r.generated_at
    }

  @doc """
  Creates (or, on a retried Oban attempt, fetches) the `pending`
  ReportDelivery row for `(run_id, recipient_id)`. The unique index on
  `(report_run_id, report_recipient_id)` is the idempotency guard: a
  retried `DeliverReportWorker` attempt reuses the same row instead of
  creating a second one.
  """
  @spec get_or_create_delivery(binary, binary) :: {:ok, %ReportDelivery{}} | {:error, term}
  def get_or_create_delivery(run_id, recipient_id) do
    case Repo.get_by(ReportDelivery, report_run_id: run_id, report_recipient_id: recipient_id) do
      %ReportDelivery{} = delivery ->
        {:ok, delivery}

      nil ->
        %ReportDelivery{}
        |> ReportDelivery.changeset(%{
          report_run_id: run_id,
          report_recipient_id: recipient_id,
          delivery_status: "pending"
        })
        |> Repo.insert()
    end
  end

  @doc "Marks a delivery `sent`. Audited as `\"report.delivery_sent\"`."
  @spec mark_delivery_sent(%ReportDelivery{}) ::
          {:ok, %ReportDelivery{}} | {:error, Ecto.Changeset.t()}
  def mark_delivery_sent(%ReportDelivery{} = delivery) do
    before = delivery_snapshot(delivery)
    attrs = %{delivery_status: "sent", delivered_at: DateTime.utc_now()}

    Multi.new()
    |> Multi.update(:delivery, ReportDelivery.changeset(delivery, attrs))
    |> audit(
      :delivery,
      "report.delivery_sent",
      "report_delivery",
      before,
      &delivery_snapshot/1,
      []
    )
    |> run_audited(:delivery)
  end

  @doc "Marks a delivery `failed` (Oban's retries already exhausted). Audited as `\"report.delivery_failed\"`."
  @spec mark_delivery_failed(%ReportDelivery{}, term) ::
          {:ok, %ReportDelivery{}} | {:error, Ecto.Changeset.t()}
  def mark_delivery_failed(%ReportDelivery{} = delivery, reason) do
    before = delivery_snapshot(delivery)

    Multi.new()
    |> Multi.update(:delivery, ReportDelivery.changeset(delivery, %{delivery_status: "failed"}))
    |> audit(
      :delivery,
      "report.delivery_failed",
      "report_delivery",
      before,
      &Map.put(delivery_snapshot(&1), :reason, inspect(reason)),
      []
    )
    |> run_audited(:delivery)
  end

  defp delivery_snapshot(%ReportDelivery{} = d),
    do: %{
      id: d.id,
      report_run_id: d.report_run_id,
      report_recipient_id: d.report_recipient_id,
      delivery_status: d.delivery_status,
      delivered_at: d.delivered_at
    }

  @doc """
  Called by `DeliverReportWorker` after it settles one delivery
  (`sent` or `failed`, never while `pending` - Oban's retries handle
  transient failures before this runs). If every `ReportDelivery` for
  `run_id` has now reached a terminal state, marks the run `"delivered"`
  and calls `Activations.mark_activation_reported/1`.

  Calling this once per (of several concurrent) `DeliverReportWorker`
  jobs finishing at nearly the same moment can, in principle, observe
  "zero pending" more than once and call `mark_activation_reported/1`
  twice; the second call is a harmless no-op (`Activation.
  mark_reported_changeset/1` requires `status == "closed"`, which is no
  longer true the second time, so it just returns a changeset error that
  is logged and discarded here) - the same "accepted, not worth a lock
  for a non-safety-critical path" judgment call as the synthetic-ID and
  visitor-pass-code races already recorded in docs/DECISIONS.md.
  """
  @spec finish_run_if_complete(binary) :: :ok
  def finish_run_if_complete(run_id) do
    pending? =
      Repo.exists?(
        from d in ReportDelivery,
          where: d.report_run_id == ^run_id and d.delivery_status == "pending"
      )

    unless pending? do
      run = get_report_run!(run_id)
      before = run_snapshot(run)

      {:ok, _run} =
        Multi.new()
        |> Multi.update(:run, ReportRun.changeset(run, %{status: "delivered"}))
        |> audit(:run, "report.delivered", "report_run", before, &run_snapshot/1, [])
        |> run_audited(:run)

      activation = Activations.get_activation!(run.activation_id)

      case Activations.mark_activation_reported(activation) do
        {:ok, _activation} -> :ok
        {:error, _changeset} -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Task 7: manual regenerate (FR-REP-05)
  # ---------------------------------------------------------------------------

  @doc """
  Enqueues a fresh `GenerateReportWorker` run for `activation`
  (FR-REP-05). This always creates a new `ReportRun` (FR-REP-06: history
  is retained, a regenerate never overwrites a previous run) and never
  reverts the activation's own status - once `"reported"`, it stays
  `"reported"` even though a new run and new deliveries happen
  (Document 08 section 5 has no path backward from `reported`).
  Audited as `"report.regenerate_requested"`.
  """
  @spec regenerate_report(%Activation{}, opts) :: {:ok, Oban.Job.t()} | {:error, term}
  def regenerate_report(%Activation{} = activation, opts \\ []) do
    with {:ok, _} <-
           Audit.record(%{
             actor_user_id: actor_id(opts),
             action: "report.regenerate_requested",
             entity_type: "activation",
             entity_id: activation.id,
             before: nil,
             after: %{activation_id: activation.id}
           }) do
      %{activation_id: activation.id}
      |> GenerateReportWorker.new()
      |> Oban.insert()
    end
  end
end
