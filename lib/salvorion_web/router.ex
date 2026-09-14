defmodule SalvorionWeb.Router do
  use SalvorionWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Requires a valid RS256 access token and a role permitted for the matched
  # route by SalvorionWeb.RBAC (Document 10, section 1). To apply one rule to
  # a whole pipeline instead of the per-route table, pass `roles: [...]`.
  pipeline :authenticated do
    plug SalvorionWeb.Plugs.Authorize
  end

  # Public: PowerSync fetches the signing public key from here.
  scope "/.well-known", SalvorionWeb do
    pipe_through :api

    get "/jwks.json", JWKSController, :show
  end

  # Public auth endpoints: nothing here can require a token.
  scope "/api/auth", SalvorionWeb do
    pipe_through :api

    post "/login", AuthController, :login
    post "/refresh", AuthController, :refresh
  end

  # Everything else under /api requires a valid token + an RBAC row
  # (SalvorionWeb.RBAC, Document 10 section 1).
  scope "/api", SalvorionWeb do
    pipe_through [:api, :authenticated]

    get "/auth/me", AuthController, :me

    # --- Accounts (Task 3) -------------------------------------------------
    post "/users", UserController, :create
    get "/users", UserController, :index
    get "/users/:id", UserController, :show
    patch "/users/:id/role", UserController, :update_role
    post "/users/:id/deactivate", UserController, :deactivate

    post "/devices", DeviceController, :create
    post "/devices/:id/revoke", DeviceController, :revoke

    post "/warden-assignments", WardenAssignmentController, :create
    get "/warden-assignments", WardenAssignmentController, :index

    # --- Organisation (Task 4) ----------------------------------------------
    get "/faculties", FacultyController, :index
    post "/faculties", FacultyController, :create
    get "/departments", DepartmentController, :index
    post "/departments", DepartmentController, :create
    get "/programmes", ProgrammeController, :index
    post "/programmes", ProgrammeController, :create

    # --- Locations (Task 5) --------------------------------------------------
    get "/assembly-points", AssemblyPointController, :index
    post "/assembly-points", AssemblyPointController, :create
    get "/assembly-points/hierarchy", AssemblyPointController, :hierarchy
    get "/zones", ZoneController, :index
    post "/zones", ZoneController, :create
    get "/areas", AreaController, :index
    post "/areas", AreaController, :create
    post "/areas/:id/departments", AreaController, :link_department
    delete "/areas/:id/departments/:dept_id", AreaController, :unlink_department

    # --- Roster (Task 6) -----------------------------------------------------
    get "/people", PersonController, :index
    get "/people/lookup", PersonController, :lookup
    get "/people/:id", PersonController, :show
    post "/roster-imports", RosterImportController, :create
    get "/roster-imports", RosterImportController, :index
    post "/visitors", VisitorController, :create

    # --- Activations (Task 7) ------------------------------------------------
    post "/activations", ActivationController, :create
    patch "/activations/:id/close", ActivationController, :close
    post "/activations/:id/start", ActivationController, :start
    get "/activations", ActivationController, :index
    get "/activations/:id", ActivationController, :show

    # --- Accountability (Task 8) ---------------------------------------------
    post "/activations/:id/events", EventController, :create

    get "/activations/:id/roll-call", RollCallController, :show
    get "/activations/:id/zones/:zone_id/roll-call", RollCallController, :zone

    post "/activations/:id/people/:person_id/resolve-contradiction",
         ContradictionController,
         :resolve

    get "/activations/:id/dashboard/summary", DashboardController, :summary
    get "/activations/:id/dashboard/departments", DashboardController, :departments
    get "/activations/:id/dashboard/faculties", DashboardController, :faculties
    get "/activations/:id/dashboard/zones", DashboardController, :zones
    get "/activations/:id/dashboard/unaccounted", DashboardController, :unaccounted

    # --- Reporting (Task 11) -------------------------------------------------
    post "/report-recipients", ReportRecipientController, :create
    get "/report-recipients", ReportRecipientController, :index
    patch "/report-recipients/:id", ReportRecipientController, :update

    get "/activations/:id/reports", ReportController, :index
    get "/activations/:id/reports/:run_id/download", ReportController, :download
    post "/activations/:id/reports/regenerate", ReportController, :regenerate
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:salvorion, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: SalvorionWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
