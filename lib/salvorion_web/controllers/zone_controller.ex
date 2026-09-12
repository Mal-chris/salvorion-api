defmodule SalvorionWeb.ZoneController do
  @moduledoc """
  Zones (Task 5). Reads: any authenticated user. Writes: admin,
  osh_officer (Document 10 section 1, "Manage assembly points, zones,
  areas").
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Locations
  alias Salvorion.Locations.Zone

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Locations.list_zones(), &zone_json/1)})
  end

  def create(conn, params) do
    with {:ok, zone} <- Locations.create_zone(params, actor: conn.assigns.current_user_id) do
      conn |> put_status(:created) |> json(%{data: zone_json(zone)})
    end
  end

  defp zone_json(%Zone{} = z),
    do: %{id: z.id, number: z.number, assembly_point_id: z.assembly_point_id}
end
