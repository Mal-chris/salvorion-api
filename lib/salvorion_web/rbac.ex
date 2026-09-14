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

  Routes that are public (login, refresh, the JWKS endpoint) are not
  listed: they are simply not piped through the plug in the router.

  Two rows in Document 10 section 1 cannot be expressed as a route-level
  role list at all, because they scope by *which* row of another table the
  requester owns, not by role:

    * "View live dashboard ... Own zone/area only" and "Conduct roll call
      ... Own assigned zone/area only" (Safety Warden) — `GET
      /api/activations/:id/roll-call` allows only `warden` at the route
      level, and the controller calls `Accountability.list_roll_call/2`
      with the *current authenticated user* (never a `user_id` read from
      the request), which internally scopes to that user's own
      `WardenAssignment` rows and returns `{:error, :no_assignment}` for
      a warden with none. There is no parameter anywhere on this route
      that could name a different warden.
    * `POST /api/devices/:id/revoke`'s "admin, or the device's own user"
      — every authenticated role passes this table's gate, and
      `DeviceController.revoke/2` itself checks `current_role == "admin"
      or device.user_id == current_user_id`, returning 403 otherwise.
  """

  @admin "admin"
  @osh "osh_officer"
  @warden "warden"
  @viewer "report_viewer"

  @all_roles [@admin, @osh, @warden, @viewer]

  # verb, path pattern (as declared in the router)  => allowed roles
  @matrix %{
    # ---------------------------------------------------------------------
    # Auth
    # ---------------------------------------------------------------------

    # Any authenticated user may inspect their own session.
    {"GET", "/api/auth/me"} => @all_roles,

    # ---------------------------------------------------------------------
    # Accounts (Task 3) — Document 10 §1 "Manage users and roles": Yes / No / No / No
    # ---------------------------------------------------------------------
    {"POST", "/api/users"} => [@admin],
    {"GET", "/api/users"} => [@admin],
    {"GET", "/api/users/:id"} => [@admin],
    {"PATCH", "/api/users/:id/role"} => [@admin],
    {"POST", "/api/users/:id/deactivate"} => [@admin],

    # Device self-registration is not itself a §1 row (every role must be
    # able to register their own device to sign in); revoke is
    # "admin, or the device's own user" — the ownership half is not
    # expressible here, see moduledoc.
    {"POST", "/api/devices"} => @all_roles,
    {"POST", "/api/devices/:id/revoke"} => @all_roles,

    # "Manage warden assignments": Yes / Yes / No / No
    {"POST", "/api/warden-assignments"} => [@admin, @osh],
    {"GET", "/api/warden-assignments"} => [@admin, @osh],

    # ---------------------------------------------------------------------
    # Organisation (Task 4) — Document 10 §1 "Manage departments, faculties,
    # programmes": Yes / No / No / No. Reads: §2's data classification
    # ("Directory information ... visible to any authenticated user role
    # in the course of their duties").
    # ---------------------------------------------------------------------
    {"GET", "/api/faculties"} => @all_roles,
    {"POST", "/api/faculties"} => [@admin],
    {"GET", "/api/departments"} => @all_roles,
    {"POST", "/api/departments"} => [@admin],
    {"GET", "/api/programmes"} => @all_roles,
    {"POST", "/api/programmes"} => [@admin],

    # ---------------------------------------------------------------------
    # Locations (Task 5) — Document 10 §1 "Manage assembly points, zones,
    # areas": Yes / Yes / No / No. Reads: §2 directory information, as above.
    # ---------------------------------------------------------------------
    {"GET", "/api/assembly-points"} => @all_roles,
    {"POST", "/api/assembly-points"} => [@admin, @osh],
    {"GET", "/api/assembly-points/hierarchy"} => @all_roles,
    {"GET", "/api/zones"} => @all_roles,
    {"POST", "/api/zones"} => [@admin, @osh],
    {"GET", "/api/areas"} => @all_roles,
    {"POST", "/api/areas"} => [@admin, @osh],
    {"POST", "/api/areas/:id/departments"} => [@admin, @osh],
    {"DELETE", "/api/areas/:id/departments/:dept_id"} => [@admin, @osh],

    # ---------------------------------------------------------------------
    # Roster (Task 6)
    # ---------------------------------------------------------------------

    # Directory information (§2: "visible to any authenticated user role
    # in the course of their duties") — widened to all four roles
    # (Document 25/26, Task 1): report_viewer was excluded for no
    # documented reason, and PowerSync's own sync config already
    # replicates the full `people` table unconditionally to every role
    # (`docker/powersync/sync-config.yaml`), so the HTTP route was
    # narrower than the data a report_viewer's client already has.
    {"GET", "/api/people"} => @all_roles,
    {"GET", "/api/people/:id"} => @all_roles,
    {"GET", "/api/people/lookup"} => @all_roles,

    # "Import roster data": Yes / No / No / No
    {"POST", "/api/roster-imports"} => [@admin],
    {"GET", "/api/roster-imports"} => [@admin],

    # "Register a visitor": Yes / Yes / Yes / No
    {"POST", "/api/visitors"} => [@admin, @osh, @warden],

    # ---------------------------------------------------------------------
    # Activations (Task 7)
    # ---------------------------------------------------------------------

    # "Start an activation" / "Close an activation": blank / Yes / blank /
    # blank — OSH Officer only, deliberately NOT System Administrator
    # (docs/DECISIONS.md, "Starting/closing an activation is OSH Officer
    # only, not System Administrator", from Prompt 5). Do not widen this
    # to match Locations/Organisation's admin+osh shape.
    {"POST", "/api/activations"} => [@osh],
    {"PATCH", "/api/activations/:id/close"} => [@osh],
    {"POST", "/api/activations/:id/start"} => [@osh],

    # "View activation history": Yes / Yes / No / Yes (read-only)
    {"GET", "/api/activations"} => [@admin, @osh, @viewer],

    # Same row for the single-activation read, extended to `warden`: a
    # warden legitimately needs to see the activation they are working
    # (status, type, timing) even though "View activation history" lists
    # them as No — that row is about the *list* of past activations, not
    # "can a warden see the one activation currently in front of them".
    # Flagged as a judgment call, not a literal §1 entry — see report.
    {"GET", "/api/activations/:id"} => [@admin, @osh, @viewer, @warden],

    # ---------------------------------------------------------------------
    # Accountability (Task 8)
    # ---------------------------------------------------------------------

    # "Perform sign-in (scan/manual)" (Yes/Yes/Yes/No) and "Register a
    # visitor" (Yes/Yes/Yes/No) share this one ingest endpoint with every
    # other event kind. The "override" kind's extra osh_officer/admin-only
    # check already lives in Accountability.ingest_event/2 (Prompt 6) and
    # is deliberately not duplicated here; this row only gets a warden far
    # enough to be authenticated and reach the endpoint at all. Note:
    # taken literally, §1's "Conduct roll call" row lists only Safety
    # Warden as Yes, so an admin/osh_officer posting a `roll_call` kind
    # here is not itself a listed permission — allowed anyway because
    # this is one shared ingest endpoint for every kind, not a
    # roll-call-specific one; see report.
    {"POST", "/api/activations/:id/events"} => [@admin, @osh, @warden],

    # "Conduct roll call ... Own assigned zone/area only" (Safety Warden
    # only). Scoping to "own" is not a role-list concern — see moduledoc.
    {"GET", "/api/activations/:id/roll-call"} => [@warden],

    # "View unaccounted list (all zones)": Yes / Yes / No / No. This is the
    # zone drill-down OSH/admin use from the dashboard.
    {"GET", "/api/activations/:id/zones/:zone_id/roll-call"} => [@admin, @osh],

    # Confirming a contradiction is part of the warden's own roll call
    # (as above) but also something OSH/admin can do from the dashboard
    # drill-down, so both role sets are listed here.
    {"POST", "/api/activations/:id/people/:person_id/resolve-contradiction"} => [
      @warden,
      @admin,
      @osh
    ],

    # "View live dashboard": Yes / Yes / Own zone/area only / Yes
    # (read-only). The zone breakdown here is the whole-campus one (all
    # zones), so summary/departments/faculties/zones take the same three
    # roles; a warden's own-scope view is the roll-call routes above,
    # not these.
    {"GET", "/api/activations/:id/dashboard/summary"} => [@admin, @osh, @viewer],
    {"GET", "/api/activations/:id/dashboard/departments"} => [@admin, @osh, @viewer],
    {"GET", "/api/activations/:id/dashboard/faculties"} => [@admin, @osh, @viewer],
    {"GET", "/api/activations/:id/dashboard/zones"} => [@admin, @osh, @viewer],

    # Narrower than its four siblings above (Document 25/26, Task 2):
    # "View unaccounted list (all zones)" is its own §1 row, and it is
    # explicitly Report Viewer: **No** there — unlike the aggregate
    # counts on the other four routes, this one names individuals still
    # missing, in real time, during a live activation. report_viewer was
    # previously admitted here by copying the other four dashboard
    # routes' role list rather than reading this row on its own.
    {"GET", "/api/activations/:id/dashboard/unaccounted"} => [@admin, @osh],

    # ---------------------------------------------------------------------
    # Reporting (Task 11) — Document 10 §1 "Manage report recipients":
    # Yes / Yes / No / No. Report access (list/download/regenerate) is
    # not its own §1 row; extended to report_viewer for reads (their
    # whole purpose per Document 05 §2.3) but not for regenerate, which
    # is a write action alongside recipient management.
    # ---------------------------------------------------------------------
    {"POST", "/api/report-recipients"} => [@admin, @osh],
    {"GET", "/api/report-recipients"} => [@admin, @osh],
    {"PATCH", "/api/report-recipients/:id"} => [@admin, @osh],
    {"GET", "/api/activations/:id/reports"} => [@admin, @osh, @viewer],
    {"GET", "/api/activations/:id/reports/:run_id/download"} => [@admin, @osh, @viewer],
    {"POST", "/api/activations/:id/reports/regenerate"} => [@admin, @osh],

    # ---------------------------------------------------------------------
    # Settings (Document 25/26, Task 5) — Document 10 §1 "Change system
    # settings (e.g. accountability rule)": Yes / Yes / No / No.
    # ---------------------------------------------------------------------
    {"GET", "/api/settings"} => [@admin, @osh],
    {"PATCH", "/api/settings/:key"} => [@admin, @osh],

    # ---------------------------------------------------------------------
    # Placeholder for a later prompt — no route exists for this yet.
    # "View audit log": Yes / No / No / No (FR-AUD-03).
    # ---------------------------------------------------------------------
    {"GET", "/api/audit-logs"} => [@admin]
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
