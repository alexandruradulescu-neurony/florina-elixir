defmodule Florina.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

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

    # Apply pending per-tenant migrations to all provisioned tenants on boot
    # (prod only, gated by :migrate_tenants_on_boot). Runs async + best-effort
    # AFTER the supervisor (Repo + ConnectionManager) is up, so a deploy that
    # adds tenant migrations no longer needs a manual migrate_tenants rpc.
    maybe_migrate_tenants_on_boot()

    result
  end

  defp maybe_migrate_tenants_on_boot do
    if Application.get_env(:florina, :migrate_tenants_on_boot, false) do
      Task.start(fn ->
        for tenant <- Florina.Tenants.list() do
          try do
            {:ok, pid} = Florina.Tenants.ConnectionManager.ensure_started(tenant.slug)
            Florina.Tenants.Migrator.migrate_one(pid)
            Logger.info("[boot] per-tenant migrations applied for #{tenant.slug}")
          rescue
            e -> Logger.error("[boot] tenant #{tenant.slug} migration failed: #{inspect(e)}")
          catch
            kind, value ->
              Logger.error("[boot] tenant #{tenant.slug} migration #{kind}: #{inspect(value)}")
          end
        end
      end)
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FlorinaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
