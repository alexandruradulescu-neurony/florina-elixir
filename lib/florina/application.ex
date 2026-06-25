defmodule Florina.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FlorinaWeb.Telemetry,
      Florina.Vault,
      Florina.Repo,
      Florina.Tenants.ConnectionManager,
      {DNSCluster, query: Application.get_env(:florina, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Florina.PubSub},
      # Background job processing (Oban)
      {Oban, Application.fetch_env!(:florina, Oban)},
      # Start a worker by calling: Florina.Worker.start_link(arg)
      # {Florina.Worker, arg},
      # Start to serve requests, typically the last entry
      FlorinaWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Florina.Supervisor]
    result = Supervisor.start_link(children, opts)

    # If ADMIN_EMAIL + ADMIN_PASSWORD env vars are set and no admin row exists,
    # seed the first operator account automatically. Runs after the repo is up.
    Florina.Admins.ensure_seed_from_env()

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FlorinaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
