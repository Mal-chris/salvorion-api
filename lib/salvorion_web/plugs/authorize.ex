defmodule SalvorionWeb.Plugs.Authorize do
  @moduledoc """
  Authenticates the request with a Guardian access token and authorises it
  against the RBAC matrix (Document 10, section 1).

  Steps, in order:

    1. Read `Authorization: Bearer <token>`; verify signature (RS256), expiry,
       `typ == "access"`, that (if the token carries a `device_id` claim)
       the device is not revoked (`devices.revoked_at`, Document 10 section
       4), and that the token's user is still `active` (Document 25, Task
       7) — all via `Salvorion.Accounts.Guardian.verify_access_token/1`, the
       one place this logic lives; `SalvorionWeb.UserSocket` calls the same
       function for the real-time layer. Missing/invalid/revoked/deactivated -> 401.
    2. Read the `role` claim (no database round-trip) and compare it with the
       roles allowed for the matched route. Not allowed -> 403.

  Roles come from one of two places, in this order of precedence:

    * `plug SalvorionWeb.Plugs.Authorize, roles: [...]` in a pipeline, which
      applies one rule to every route piped through it; or
    * `SalvorionWeb.RBAC.allowed_roles/2`, looked up by the request's verb and
      the matched route pattern, e.g. `{"GET", "/api/users/:id"}`.

  A route with no rule anywhere is denied for everyone (fail closed).

  On success the conn gets `:current_user_id`, `:current_role`,
  `:current_device_id` and `:token_claims` assigns.
  """

  @behaviour Plug

  import Plug.Conn

  alias Salvorion.Accounts.Guardian
  alias SalvorionWeb.RBAC

  @impl true
  def init(opts), do: Keyword.take(opts, [:roles])

  @impl true
  def call(conn, opts) do
    with {:ok, token} <- fetch_bearer(conn),
         {:ok, claims} <- Guardian.verify_access_token(token),
         :ok <- check_role(conn, claims, opts) do
      conn
      |> assign(:current_user_id, claims["sub"])
      |> assign(:current_role, claims["role"])
      |> assign(:current_device_id, claims["device_id"])
      |> assign(:token_claims, claims)
    else
      {:error, :forbidden} -> deny(conn, 403, "forbidden")
      {:error, _} -> deny(conn, 401, "unauthorized")
    end
  end

  defp fetch_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, String.trim(token)}
      ["bearer " <> token] when byte_size(token) > 0 -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end

  defp check_role(conn, %{"role" => role}, opts) when is_binary(role) do
    allowed =
      case Keyword.fetch(opts, :roles) do
        {:ok, roles} -> roles
        :error -> RBAC.allowed_roles(conn.method, matched_route(conn))
      end

    if is_list(allowed) and role in allowed, do: :ok, else: {:error, :forbidden}
  end

  # A token without a role claim was not issued by us in this shape; treat as
  # unauthenticated rather than guessing a role.
  defp check_role(_conn, _claims, _opts), do: {:error, :missing_role}

  # The route pattern the router matched (e.g. "/api/users/:id"), which is
  # what RBAC keys on. Falls back to the raw path if unavailable.
  defp matched_route(conn) do
    with router when is_atom(router) and not is_nil(router) <- conn.private[:phoenix_router],
         %{route: route} <-
           Phoenix.Router.route_info(router, conn.method, conn.request_path, conn.host) do
      route
    else
      _ -> conn.request_path
    end
  end

  defp deny(conn, status, detail) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{errors: %{detail: detail}})
    |> halt()
  end
end
