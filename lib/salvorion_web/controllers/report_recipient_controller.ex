defmodule SalvorionWeb.ReportRecipientController do
  @moduledoc """
  Report recipients (Task 2/8; FR-REP-04). admin and osh_officer only -
  Document 10 section 1 lists OSH Officer as managing report recipients
  alongside the System Administrator.
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Reporting
  alias Salvorion.Reporting.ReportRecipient

  def index(conn, params) do
    active_only = params["active_only"] != "false"

    json(conn, %{
      data:
        Enum.map(Reporting.list_report_recipients(active_only: active_only), &recipient_json/1)
    })
  end

  def create(conn, params) do
    with {:ok, recipient} <-
           Reporting.create_report_recipient(params, actor: conn.assigns.current_user_id) do
      conn |> put_status(:created) |> json(%{data: recipient_json(recipient)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    recipient = Reporting.get_report_recipient!(id)

    with {:ok, recipient} <-
           Reporting.update_report_recipient(recipient, params,
             actor: conn.assigns.current_user_id
           ) do
      json(conn, %{data: recipient_json(recipient)})
    end
  end

  defp recipient_json(%ReportRecipient{} = r),
    do: %{id: r.id, name: r.name, email: r.email, role: r.role, active: r.active}
end
