defmodule SalvorionWeb.DepartmentController do
  @moduledoc """
  Departments (Task 4). Reads: any authenticated user. Writes: admin
  only (Document 10 section 1, "Manage departments, faculties,
  programmes" — Yes/No/No/No).
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Organisation
  alias Salvorion.Organisation.Department

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Organisation.list_departments(), &department_json/1)})
  end

  def create(conn, params) do
    with {:ok, department} <-
           Organisation.create_department(params, actor: conn.assigns.current_user_id) do
      conn |> put_status(:created) |> json(%{data: department_json(department)})
    end
  end

  defp department_json(%Department{} = d),
    do: %{id: d.id, name: d.name, code: d.code, faculty_id: d.faculty_id}
end
