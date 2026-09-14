defmodule SalvorionWeb.ReportController do
  @moduledoc """
  Reading and regenerating an activation's reports (Task 7/8; FR-REP-05,
  FR-REP-06). Listing and downloading extend to `report_viewer`
  (read-only); regenerating is admin/osh_officer only, matching who
  manages recipients.
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Activations
  alias Salvorion.Reporting
  alias Salvorion.Reporting.{ReportDelivery, ReportRun}

  @ready_statuses ~w(generated delivered)

  @doc "GET /api/activations/:id/reports - every ReportRun for the activation, newest first, deliveries included."
  def index(conn, %{"id" => activation_id}) do
    json(conn, %{data: Enum.map(Reporting.list_report_runs(activation_id), &run_json/1)})
  end

  @doc """
  GET /api/activations/:id/reports/:run_id/download - streams the PDF.
  404 `:report_not_ready` when the run has no PDF yet (`pending`) or
  never will (`failed`) - never a broken/partial download.
  """
  def download(conn, %{"id" => activation_id, "run_id" => run_id}) do
    case Reporting.get_report_run(activation_id, run_id) do
      nil ->
        {:error, :not_found}

      %ReportRun{status: status} when status not in @ready_statuses ->
        {:error, :report_not_ready}

      %ReportRun{pdf_path: pdf_path} = run ->
        conn
        |> put_resp_content_type("application/pdf", nil)
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="activation-report-#{run.activation_id}.pdf")
        )
        |> send_file(200, pdf_path)
    end
  end

  @doc "POST /api/activations/:id/reports/regenerate - FR-REP-05."
  def regenerate(conn, %{"id" => activation_id}) do
    activation = Activations.get_activation!(activation_id)

    with {:ok, _job} <-
           Reporting.regenerate_report(activation, actor: conn.assigns.current_user_id) do
      conn |> put_status(:accepted) |> json(%{data: %{activation_id: activation_id}})
    end
  end

  defp run_json(%ReportRun{} = run) do
    %{
      id: run.id,
      activation_id: run.activation_id,
      status: run.status,
      pdf_path: run.pdf_path,
      generated_at: run.generated_at,
      inserted_at: run.inserted_at,
      deliveries: Enum.map(run.deliveries, &delivery_json/1)
    }
  end

  defp delivery_json(%ReportDelivery{} = d) do
    %{
      id: d.id,
      report_recipient_id: d.report_recipient_id,
      recipient_name: d.report_recipient && d.report_recipient.name,
      recipient_email: d.report_recipient && d.report_recipient.email,
      delivery_status: d.delivery_status,
      delivered_at: d.delivered_at
    }
  end
end
