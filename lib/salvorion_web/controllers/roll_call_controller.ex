defmodule SalvorionWeb.RollCallController do
  @moduledoc """
  A warden's roll-call list, and OSH/admin's zone drill-down (Task 8).

  `show/2` is `warden` ONLY at the route level (`SalvorionWeb.RBAC`) and
  always calls `Accountability.list_roll_call/2` with the CURRENT
  authenticated user (`conn.assigns.current_user_id`) — never a
  `user_id` read from the request body or query string. There is no
  parameter anywhere on this route that could name a different warden;
  scoping to "own assigned zone/area" (Document 10 section 1, "Conduct
  roll call") happens entirely inside `list_roll_call/2` itself, via
  that user's `WardenAssignment` rows.
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.{Accountability, Accounts, Activations}

  def show(conn, %{"id" => activation_id}) do
    activation = Activations.get_activation!(activation_id)
    user = Accounts.get_user!(conn.assigns.current_user_id)

    with {:ok, roll_call} <- Accountability.list_roll_call(activation, user) do
      json(conn, %{data: roll_call_json(roll_call)})
    end
  end

  def zone(conn, %{"id" => activation_id, "zone_id" => zone_id}) do
    activation = Activations.get_activation!(activation_id)
    {:ok, roll_call} = Accountability.list_roll_call_for_zone(activation, zone_id)
    json(conn, %{data: roll_call_json(roll_call)})
  end

  defp roll_call_json(%{
         unaccounted: unaccounted,
         flagged: flagged,
         accounted: accounted,
         counts: counts
       }) do
    %{
      unaccounted: Enum.map(unaccounted, &row_json/1),
      flagged: Enum.map(flagged, &row_json/1),
      accounted: Enum.map(accounted, &row_json/1),
      counts: counts
    }
  end

  defp row_json(row) do
    %{
      person_id: row.person_id,
      id_number: row.id_number,
      first_name: row.first_name,
      last_name: row.last_name,
      type: row.type,
      department_name: row.department_name,
      usual_area_name: row.usual_area_name,
      status: row.status,
      source_kind: row.source_kind,
      contradiction_open?: row.contradiction_open?,
      last_event_at: row.last_event_at
    }
  end
end
