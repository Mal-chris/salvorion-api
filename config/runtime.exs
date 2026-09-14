import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/salvorion start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :salvorion, SalvorionWeb.Endpoint, server: true
end

config :salvorion, SalvorionWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Path to the RSA private key (PEM) that signs JWTs (RS256). Only the *path*
# lives in configuration; the key material stays on disk, outside git
# (/priv/keys/ is git-ignored). See .env.example for how to generate a pair.
guardian_key_path =
  case {System.get_env("GUARDIAN_PRIVATE_KEY_PATH"), config_env()} do
    {nil, :prod} ->
      raise """
      environment variable GUARDIAN_PRIVATE_KEY_PATH is missing.
      It must point at an RSA private key in PEM format, e.g. generated with:
        openssl genrsa -out guardian_private.pem 2048
      """

    {nil, _} ->
      "priv/keys/dev_private.pem"

    {path, _} ->
      path
  end

config :salvorion, Salvorion.Accounts.Keys, private_key_path: guardian_key_path

if url = System.get_env("GOTENBERG_URL") do
  config :salvorion, :gotenberg_url, url
end

if from = System.get_env("REPORT_FROM_EMAIL") do
  config :salvorion, :report_from_email, from
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :salvorion, Salvorion.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :salvorion, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :salvorion, SalvorionWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :salvorion, SalvorionWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :salvorion, SalvorionWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Mailer (Prompt 11, Task 6; docs/DECISIONS.md)
  #
  # Amazon SES, prod ONLY - dev uses Swoosh.Adapters.Local (config.exs),
  # test uses Swoosh.Adapters.Test (config/test.exs). Guarded by
  # config_env() exactly like the Guardian key path above, so there is
  # no code path in dev or test that ever tries to reach AWS. This is
  # the interface being made complete and swappable via config alone;
  # SES itself is unverified until real AWS credentials exist.
  aws_access_key_id =
    System.get_env("AWS_ACCESS_KEY_ID") ||
      raise "environment variable AWS_ACCESS_KEY_ID is missing (required for SES in prod)"

  aws_secret_access_key =
    System.get_env("AWS_SECRET_ACCESS_KEY") ||
      raise "environment variable AWS_SECRET_ACCESS_KEY is missing (required for SES in prod)"

  aws_region = System.get_env("AWS_REGION") || "us-east-1"

  config :ex_aws,
    access_key_id: aws_access_key_id,
    secret_access_key: aws_secret_access_key,
    region: aws_region

  config :salvorion, Salvorion.Mailer, adapter: Swoosh.Adapters.AmazonSES, region: aws_region
end
