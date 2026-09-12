defmodule SalvorionWeb.AssemblyPointController do
  @moduledoc """
  Assembly points (Task 5). Reads: any authenticated user. Writes:
  admin, osh_officer (Document 10 section 1, "Manage assembly points,
  zones, areas").
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Locations
  alias Salvorion.Locations.AssemblyPoint

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Locations.list_assembly_points(), &assembly_point_json/1)})
  end

  def create(conn, params) do
    with {:ok, assembly_point} <-
           Locations.create_assembly_point(params, actor: conn.assigns.current_user_id) do
      conn |> put_status(:created) |> json(%{data: assembly_point_json(assembly_point)})
    end
  end

  @doc "The full assembly point -> zones -> areas -> departments tree (Document 11 section 2.4)."
  def hierarchy(conn, _params) do
    json(conn, %{data: Enum.map(Locations.get_assembly_point_hierarchy(), &hierarchy_json/1)})
  end

  defp hierarchy_json(%AssemblyPoint{} = ap) do
    ap
    |> assembly_point_json()
    |> Map.put(:zones, Enum.map(ap.zones, &zone_hierarchy_json/1))
  end

  defp zone_hierarchy_json(zone) do
    %{id: zone.id, number: zone.number}
    |> Map.put(:areas, Enum.map(zone.areas, &area_hierarchy_json/1))
  end

  defp area_hierarchy_json(area) do
    %{id: area.id, name: area.name, building: area.building, floor: area.floor}
    |> Map.put(
      :departments,
      Enum.map(area.departments, &%{id: &1.id, name: &1.name, code: &1.code})
    )
  end

  defp assembly_point_json(%AssemblyPoint{} = ap),
    do: %{
      id: ap.id,
      name: ap.name,
      description: ap.description,
      latitude: ap.latitude,
      longitude: ap.longitude
    }
end
