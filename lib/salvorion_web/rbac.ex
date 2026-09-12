defmodule SalvorionWeb.RBAC do
  @moduledoc """
  The role-based access control matrix (Document 10, section 1), as data.

  Each entry maps a route, written exactly as it appears in the router
  (`{HTTP verb, path pattern}`), to the roles allowed to call it. Role names
  are the `users.role` values:

      System Administrator -> "admin"
      OSH Officer          -> "osh_officer"
      Safety Warden        -> "warden"
      Report Viewer        -> "report_viewer"

  `SalvorionWeb.Plugs.Authorize` looks the matched route up here. A route
  that is behind the plug but missing from this table is denied (403) for
  everyone, so forgetting to add a row fails closed rather than open.

  Routes that are public (login, the JWKS endpoint) are not listed: they are
  simply not piped through the plug in the router.
  """

  @admin "admin"
  @osh "osh_officer"
  @warden "warden"
  @viewer "report_viewer"

  @all_roles [@admin, @osh, @warden, @viewer]

  # verb, path pattern (as declared in the router)  => allowed roles
  @matrix %{
    # --- Auth (this prompt) -------------------------------------------------
    # Any authenticated user may inspect their own session.
    {"GET", "/api/auth/me"} => @all_roles,

    # --- Placeholders for later prompts -------------------------------------
    # Rows below are declared now so the shape of the table can be checked
    # against Document 10 section 1; the routes themselves do not exist yet
    # and will be added, with their real controllers, in later prompts.
    #
    # Accounts administration (users, roles, devices, warden assignments)
    {"GET", "/api/users"} => [@admin],
    {"POST", "/api/users"} => [@admin],
    {"PATCH", "/api/users/:id/role"} => [@admin],
    {"POST", "/api/users/:id/deactivate"} => [@admin],
    {"POST", "/api/devices"} => @all_roles,
    {"POST", "/api/devices/:id/revoke"} => [@admin],
    {"POST", "/api/warden_assignments"} => [@admin, @osh],
    # Audit trail
    {"GET", "/api/audit_logs"} => [@admin]
  }

  @doc "The full matrix, for inspection and for the router to declare."
  @spec matrix() :: %{{String.t(), String.t()} => [String.t()]}
  def matrix, do: @matrix

  @doc "All known role names."
  @spec roles() :: [String.t()]
  def roles, do: @all_roles

  @doc """
  Roles allowed for a `{verb, route_pattern}`; `:undeclared` when the route
  has no row (which the plug treats as deny-all).
  """
  @spec allowed_roles(String.t(), String.t()) :: [String.t()] | :undeclared
  def allowed_roles(verb, route_pattern) do
    Map.get(@matrix, {String.upcase(verb), route_pattern}, :undeclared)
  end
end
