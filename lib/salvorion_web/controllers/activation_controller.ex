defmodule SalvorionWeb.ActivationController do
  @moduledoc """
  The activation lifecycle (Task 7). Starting and closing are
  `osh_officer` ONLY — deliberately not `admin` (docs/DECISIONS.md,
  "Starting/closing an activation is OSH Officer only, not System
  Administrator", Prompt 5); do not widen `SalvorionWeb.RBAC`'s entries
  for these three routes to match Locations/Organisation's admin+osh
  shape.

  `close/2` also enqueues `GenerateReportWorker` (Prompt 11, FR-REP-01;
  Document 08 section 4's sequence diagram: the API layer enqueues the
  report job right after the Activations context reports the
  transition succeeded, not the context itself — `Salvorion.Activations`
  has no dependency on `Salvorion.Reporting`, and this keeps it that way).
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Activations
  alias Salvorion.Activations.Activation
  alias Salvorion.Reporting.Workers.GenerateReportWorker

  @known_filters ~w(status activation_type)

  @doc "POST /api/activations — creates and starts immediately (the common case; see Activations.start_activation/2)."
  def create(conn, params) do
    with {:ok, activation} <-
           Activations.start_activation(params, actor: conn.assigns.current_user_id) do
      conn |> put_status(:created) |> json(%{data: activation_json(activation)})
    end
  end

  @doc "POST /api/activations/:id/start — starts a previously scheduled activation."
  def start(conn, %{"id" => id}) do
    with {:ok, activation} <-
           Activations.start_activation(Activations.get_activation!(id),
             actor: conn.assigns.current_user_id
           ) do
      json(conn, %{data: activation_json(activation)})
    end
  end

  def close(conn, %{"id" => id}) do
    with {:ok, activation} <-
           Activations.close_activation(Activations.get_activation!(id),
             actor: conn.assigns.current_user_id
           ) do
      {:ok, _job} = %{activation_id: activation.id} |> GenerateReportWorker.new() |> Oban.insert()
      json(conn, %{data: activation_json(activation)})
    end
  end

  def index(conn, params) do
    filters =
      for key <- @known_filters,
          value = params[key],
          not is_nil(value),
          do: {String.to_existing_atom(key), value}

    json(conn, %{data: Enum.map(Activations.list_activations(filters), &activation_json/1)})
  end

  def show(conn, %{"id" => id}) do
    json(conn, %{data: activation_json(Activations.get_activation!(id))})
  end

  defp activation_json(%Activation{} = a),
    do: %{
      id: a.id,
      activation_type: a.activation_type,
      status: a.status,
      scope: a.scope,
      started_by_id: a.started_by_id,
      closed_by_id: a.closed_by_id,
      started_at: a.started_at,
      closed_at: a.closed_at
    }
end
