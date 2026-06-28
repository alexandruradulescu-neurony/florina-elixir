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

      bin/florina rpc 'Florina.Release.provision_tenant("acme", "Acme Corp")'

  Registers the tenant in the control-plane, creates its Postgres schema
  (`tenant_<id>`) on the shared database, runs the per-tenant migrations into it,
  and seeds central config. Idempotent — safe to run again.
  """
  def provision_tenant(slug, name) do
    Florina.Tenants.Provisioner.provision(%{slug: slug, name: name})
  end

  @doc """
  Apply any pending per-tenant migrations to ALL already-provisioned tenants.

  Run after deploying a release that adds new tenant migrations (e.g. the
  encrypt_sensitive_fields migration that converts text/jsonb columns to bytea):

      bin/florina rpc 'Florina.Release.migrate_tenants()'

  This is equivalent to running `Florina.Tenants.Migrator.migrate_all/0` and
  is safe to call multiple times (Ecto's migrator is idempotent).
  """
  def migrate_tenants do
    load_app()
    Florina.Tenants.Migrator.migrate_all()
  end

  @doc """
  Create an operator admin account in production. Run against the RUNNING release node:

      bin/florina rpc 'Florina.Release.create_admin("admin@example.com", "s3cur3p@ss")'

  Returns `{:ok, admin}` on success or `{:error, changeset}` if validation fails
  (e.g. duplicate email, password too short).
  """
  def create_admin(email, password) do
    load_app()
    Florina.Admins.create_admin(%{email: email, password: password})
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
