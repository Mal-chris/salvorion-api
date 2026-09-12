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

  # Everything else under /api requires a valid token + an RBAC row.
  scope "/api", SalvorionWeb do
    pipe_through [:api, :authenticated]

    get "/auth/me", AuthController, :me
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
