defmodule Florina.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :florina

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Onboard a tenant in production. Run against the RUNNING release node:

      bin/florina rpc 'Florina.Release.provision_tenant("acme", "Acme Corp", "florina_tenant_acme")'

  Creates the tenant's own database on the configured Postgres, runs the
  per-tenant migrations into it, and registers it in the control-plane.
  Idempotent — safe to run again.
  """
  def provision_tenant(slug, name, database) do
    Florina.Tenants.Provisioner.provision(%{slug: slug, name: name, database: database})
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
