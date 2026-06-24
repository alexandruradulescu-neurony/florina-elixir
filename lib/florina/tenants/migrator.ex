defmodule Florina.Tenants.Migrator do
  @moduledoc "Runs the per-tenant migrations against tenant databases."

  @doc "Migrate every registered tenant's database."
  def migrate_all do
    for tenant <- Florina.Tenants.list() do
      {:ok, pid} = Florina.Tenants.ConnectionManager.ensure_started(tenant.slug)
      migrate_one(pid)
    end

    :ok
  end

  @doc "Migrate a single tenant database, given a started TenantRepo pid."
  def migrate_one(pid) do
    Ecto.Migrator.run(Florina.TenantRepo, path(), :up, all: true, dynamic_repo: pid)
  end

  defp path, do: Path.join([:code.priv_dir(:florina), "tenant_repo", "migrations"])
end
