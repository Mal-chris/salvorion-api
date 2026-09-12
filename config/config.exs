# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :salvorion,
  ecto_repos: [Salvorion.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :salvorion, SalvorionWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SalvorionWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Salvorion.PubSub,
  live_view: [signing_salt: "00RFj9+d"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :salvorion, Salvorion.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Guardian (JWT). Tokens are signed with RS256 using an RSA private key loaded
# at startup by Salvorion.Accounts.Keys (path set in config/runtime.exs); the
# matching public key is served at /.well-known/jwks.json for PowerSync.
# Never fall back to a symmetric secret here: a symmetric key cannot be
# published as a JWKS. See docs/DECISIONS.md.
config :salvorion, Salvorion.Accounts.Guardian,
  issuer: "salvorion",
  allowed_algos: ["RS256"],
  secret_key: {Salvorion.Accounts.Keys, :signing_jwk, []},
  # Access tokens: 15 minutes. Refresh tokens: 30 days. (Document 10, section 4)
  token_ttl: %{
    "access" => {15, :minutes},
    "refresh" => {30, :days}
  }

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
