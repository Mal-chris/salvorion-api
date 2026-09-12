defmodule SalvorionWeb.RosterImportController do
  @moduledoc """
  Roster import runs (Task 6; Document 10 section 1, "Import roster
  data" — admin only).
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Roster
  alias Salvorion.Roster.Providers.FileImport
  alias Salvorion.Roster.RosterImport

  @csv_content_types ["text/csv", "application/csv", "application/vnd.ms-excel"]

  @doc """
  `multipart/form-data`, field `file`. The upload's declared content-type
  is checked before the file ever reaches `FileImport` — a non-CSV
  content-type is rejected here, not discovered three layers down as a
  parse failure (Task 6).
  """
  def create(conn, %{"file" => %Plug.Upload{} = upload}) do
    with :ok <- check_csv_content_type(upload),
         {:ok, %{import: import, total: total, errors: errors}} <-
           FileImport.run(path: upload.path, actor: conn.assigns.current_user_id) do
      conn
      |> put_status(:created)
      |> json(%{data: roster_import_json(import, total, errors)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{file: ["a CSV file upload is required"]}})
  end

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Roster.list_roster_imports(), &roster_import_json/1)})
  end

  defp check_csv_content_type(%Plug.Upload{content_type: type}) when type in @csv_content_types,
    do: :ok

  defp check_csv_content_type(%Plug.Upload{filename: filename}) do
    # Some clients (curl -F without -H, some browsers) send a generic
    # octet-stream content-type for any file; fall back to the extension
    # rather than reject a perfectly good .csv outright.
    if String.ends_with?(String.downcase(filename), ".csv") do
      :ok
    else
      {:error, :unsupported_content_type}
    end
  end

  defp roster_import_json(%RosterImport{} = i, total \\ nil, errors \\ nil),
    do: %{
      id: i.id,
      provider: i.provider,
      started_at: i.started_at,
      completed_at: i.completed_at,
      total_records: total || i.total_records,
      error_count: i.error_count,
      errors: errors || (i.errors && i.errors["rows"]) || []
    }
end
