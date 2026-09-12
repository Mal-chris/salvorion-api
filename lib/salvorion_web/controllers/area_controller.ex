defmodule SalvorionWeb.AreaController do
  @moduledoc """
  Areas, and their links to departments (Task 5). Reads: any
  authenticated user. Writes and links: admin, osh_officer (Document 10
  section 1, "Manage assembly points, zones, areas").
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Locations
  alias Salvorion.Locations.Area

  def index(conn, params) do
    case params["zone_id"] do
      nil ->
        json(conn, %{data: Enum.map(Locations.list_areas(), &area_json/1)})

      zone_id ->
        json(conn, %{data: Enum.map(Locations.list_areas_for_zone(zone_id), &area_json/1)})
    end
  end

  def create(conn, params) do
    with {:ok, area} <- Locations.create_area(params, actor: conn.assigns.current_user_id) do
      conn |> put_status(:created) |> json(%{data: area_json(area)})
    end
  end

  def link_department(conn, %{"id" => area_id, "department_id" => department_id}) do
    with {:ok, link} <-
           Locations.link_department_to_area(department_id, area_id,
             actor: conn.assigns.current_user_id
           ) do
      conn
      |> put_status(:created)
      |> json(%{data: %{id: link.id, department_id: link.department_id, area_id: link.area_id}})
    end
  end

  def unlink_department(conn, %{"id" => area_id, "dept_id" => department_id}) do
    with {:ok, _link} <-
           Locations.unlink_department_from_area(department_id, area_id,
             actor: conn.assigns.current_user_id
           ) do
      send_resp(conn, :no_content, "")
    end
  end

  defp area_json(%Area{} = a),
    do: %{id: a.id, name: a.name, building: a.building, floor: a.floor, zone_id: a.zone_id}
end
