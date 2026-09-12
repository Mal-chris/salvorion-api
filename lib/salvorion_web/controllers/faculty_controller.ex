defmodule SalvorionWeb.FacultyController do
  @moduledoc """
  Faculties (Task 4). Reads: any authenticated user (Document 10 section
  2, directory information). Writes: admin only (Document 10 section 1,
  "Manage departments, faculties, programmes" — Yes/No/No/No; unlike
  Locations, OSH Officer is not included here).
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Organisation
  alias Salvorion.Organisation.Faculty

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Organisation.list_faculties(), &faculty_json/1)})
  end

  def create(conn, params) do
    with {:ok, faculty} <-
           Organisation.create_faculty(params, actor: conn.assigns.current_user_id) do
      conn |> put_status(:created) |> json(%{data: faculty_json(faculty)})
    end
  end

  defp faculty_json(%Faculty{} = f), do: %{id: f.id, name: f.name, code: f.code}
end
