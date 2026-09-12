defmodule SalvorionWeb.ProgrammeController do
  @moduledoc """
  Programmes (Task 4). Reads: any authenticated user. Writes: admin
  only (Document 10 section 1, "Manage departments, faculties,
  programmes" — Yes/No/No/No).
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Organisation
  alias Salvorion.Organisation.Programme

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Organisation.list_programmes(), &programme_json/1)})
  end

  def create(conn, params) do
    with {:ok, programme} <-
           Organisation.create_programme(params, actor: conn.assigns.current_user_id) do
      conn |> put_status(:created) |> json(%{data: programme_json(programme)})
    end
  end

  defp programme_json(%Programme{} = p),
    do: %{id: p.id, name: p.name, code: p.code, faculty_id: p.faculty_id}
end
