defmodule Salvorion.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SalvorionWeb.Telemetry,
      Salvorion.Repo,
      {DNSCluster, query: Application.get_env(:salvorion, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Salvorion.PubSub},
      # Start a worker by calling: Salvorion.Worker.start_link(arg)
      # {Salvorion.Worker, arg},
      # Start to serve requests, typically the last entry
      SalvorionWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Salvorion.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SalvorionWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
