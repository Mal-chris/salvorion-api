defmodule SalvorionWeb.WardenAssignmentController do
  @moduledoc """
  Warden zone/area assignments (Task 3; Document 10 section 1, "Manage
  warden assignments": admin, osh_officer).
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Accounts
  alias Salvorion.Accounts.WardenAssignment

  @doc """
  `{"user_id": ..., "zone_id": ... | "area_id": ..., "starts_at": "YYYY-MM-DD", "ends_at": null | "YYYY-MM-DD"}`

  `Accounts.assign_warden/4` takes already-parsed `Date` values, not JSON
  strings, so the date/scope parsing that any other context function
  would do itself via `Ecto.Changeset.cast/3` happens here instead; a bad
  value is still a 422 with a field error, just built directly rather
  than via a changeset (there is no changeset to attach it to before
  `assign_warden/4` runs).
  """
  def create(conn, params) do
    with {:ok, scope} <- fetch_scope(params),
         {:ok, user_id} <- fetch_required(params, "user_id"),
         {:ok, starts_at} <- fetch_date(params, "starts_at"),
         {:ok, ends_at} <- fetch_optional_date(params, "ends_at"),
         {:ok, assignment} <-
           Accounts.assign_warden(user_id, scope, {starts_at, ends_at},
             actor: conn.assigns.current_user_id
           ) do
      conn |> put_status(:created) |> json(%{data: assignment_json(assignment)})
    else
      {:field_error, field, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{field => [message]}})

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  def index(conn, params) do
    filters = if user_id = params["user_id"], do: [user_id: user_id], else: []
    json(conn, %{data: Enum.map(Accounts.list_warden_assignments(filters), &assignment_json/1)})
  end

  defp fetch_scope(%{"zone_id" => zone_id}) when is_binary(zone_id), do: {:ok, {:zone, zone_id}}
  defp fetch_scope(%{"area_id" => area_id}) when is_binary(area_id), do: {:ok, {:area, area_id}}
  defp fetch_scope(_), do: {:field_error, "zone_id", "either zone_id or area_id is required"}

  defp fetch_required(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:field_error, key, "can't be blank"}
    end
  end

  defp fetch_date(params, key) do
    with {:ok, value} <- fetch_required(params, key),
         {:ok, date} <- Date.from_iso8601(value) do
      {:ok, date}
    else
      {:field_error, _, _} = error -> error
      {:error, _reason} -> {:field_error, key, "must be a date, e.g. 2026-01-31"}
    end
  end

  defp fetch_optional_date(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      _ -> fetch_date(params, key)
    end
  end

  defp assignment_json(%WardenAssignment{} = a),
    do: %{
      id: a.id,
      user_id: a.user_id,
      zone_id: a.zone_id,
      area_id: a.area_id,
      starts_at: a.starts_at,
      ends_at: a.ends_at
    }
end
