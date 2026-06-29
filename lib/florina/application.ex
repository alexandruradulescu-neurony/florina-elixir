defmodule Florina.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        FlorinaWeb.Telemetry,
        Florina.Vault,
        Florina.Auth.LoginRateLimiter,
        Florina.Repo,
        # Dedicated background-job pool (same DB, separate pool) — only when
        # configured (prod); nil in dev/test and filtered out below.
        jobs_repo_child(),
        # Apply pending per-tenant migrations BEFORE Oban + the Endpoint start, so
        # jobs/requests never hit an out-of-date schema. Blocking + fail-loud: a
        # migration error aborts boot (and the deploy). Gated by
        # :migrate_tenants_on_boot (prod); a no-op in dev/test.
        Florina.Tenants.BootMigrator,
        {DNSCluster, query: Application.get_env(:florina, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Florina.PubSub},
        # Background job processing (Oban)
        {Oban, Application.fetch_env!(:florina, Oban)},
        # Start a worker by calling: Florina.Worker.start_link(arg)
        # {Florina.Worker, arg},
        # Start to serve requests, typically the last entry
        FlorinaWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Florina.Supervisor]
    result = Supervisor.start_link(children, opts)

    # If ADMIN_EMAIL + ADMIN_PASSWORD env vars are set and no admin row exists,
    # seed the first operator account automatically. Runs after the repo is up.
    Florina.Admins.ensure_seed_from_env()

    result
  end

  # The dedicated jobs-pool child, only when a jobs repo is configured (prod).
  defp jobs_repo_child do
    if Application.get_env(:florina, :jobs_repo), do: Florina.JobsRepo
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FlorinaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
