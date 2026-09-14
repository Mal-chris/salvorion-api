defmodule SalvorionWeb.FallbackController do
  @moduledoc """
  The one place a context's return value becomes an HTTP response
  (Task 1). Every controller in this API declares
  `action_fallback SalvorionWeb.FallbackController` and returns the
  context's raw `{:ok, ...}` / `{:error, ...}` value; a successful
  branch is rendered by the controller action itself, everything else
  falls through to here.

  An error shape not recognised below is never swallowed into a bare
  500: it is logged with the actual reason first, so a new context
  error introduced later is loud (in the logs) rather than silently
  indistinguishable from any other failure.
  """
  use SalvorionWeb, :controller

  require Logger

  # --- Validation -------------------------------------------------------

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: changeset_errors(changeset)})
  end

  # --- Not found ----------------------------------------------------------

  def call(conn, {:error, :not_found}), do: send_status(conn, :not_found)
  def call(conn, {:error, :unknown_person}), do: send_status(conn, :not_found)
  def call(conn, {:error, :activation_not_found}), do: send_status(conn, :not_found)

  # Reporting (Prompt 11, Task 8): the run exists but has no PDF to
  # serve yet (`pending`) or never will (`failed`) - never a broken or
  # partial download.
  def call(conn, {:error, :report_not_ready}), do: send_status(conn, :not_found)

  # --- Forbidden (authenticated, but not permitted for this specific
  # resource — distinct from the route-level 403 the RBAC plug already
  # gives an unauthorised role before the controller ever runs) ---------

  def call(conn, {:error, :no_assignment}), do: send_status(conn, :forbidden)
  def call(conn, {:error, :not_a_warden}), do: send_status(conn, :forbidden)
  def call(conn, {:error, :override_not_permitted}), do: send_status(conn, :forbidden)

  # A controller-level ownership check (Task 3's "admin, or the device's
  # own user" on POST /api/devices/:id/revoke) rather than a context
  # return value, but the same shape: authenticated, not permitted here.
  def call(conn, {:error, :forbidden}), do: send_status(conn, :forbidden)

  # --- Conflict -------------------------------------------------------

  def call(conn, {:error, :zone_conflict, message}), do: conflict(conn, message)

  # Activations.start_activation/2 actually returns the reason nested,
  # {:error, {:zone_conflict, message}} — both shapes are accepted so a
  # caller matching the prompt's flatter form still works.
  def call(conn, {:error, {:zone_conflict, message}}), do: conflict(conn, message)
  def call(conn, {:error, {:invalid_state, message}}), do: conflict(conn, message)

  def call(conn, {:error, :activation_not_started}), do: conflict(conn, "activation not started")
  def call(conn, {:error, :activation_closed}), do: conflict(conn, "activation closed")
  def call(conn, {:error, :no_open_contradiction}), do: conflict(conn, "no open contradiction")

  # Task 6: a roster-import upload whose content-type isn't CSV, rejected
  # before it ever reaches FileImportProvider.
  def call(conn, {:error, :unsupported_content_type}) do
    conn
    |> put_status(:unsupported_media_type)
    |> json(%{errors: %{detail: "expected a text/csv upload"}})
  end

  # --- Authentication -------------------------------------------------

  def call(conn, {:error, :invalid_credentials}), do: send_status(conn, :unauthorized)

  # --- Fallback: log what actually happened, never guess -----------------

  def call(conn, {:error, reason}) do
    Logger.error("unhandled controller error: #{inspect(reason)}")
    send_status(conn, :internal_server_error)
  end

  defp conflict(conn, message) do
    conn |> put_status(:conflict) |> json(%{error: message})
  end

  defp send_status(conn, status) do
    detail =
      status |> Plug.Conn.Status.code() |> Plug.Conn.Status.reason_phrase() |> String.downcase()

    conn |> put_status(status) |> json(%{errors: %{detail: detail}})
  end

  @doc "Changeset errors as `%{field: [\"message\", ...]}`, interpolating `count`/etc. placeholders."
  @spec changeset_errors(Ecto.Changeset.t()) :: map
  def changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
