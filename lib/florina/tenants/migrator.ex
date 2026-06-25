defmodule Florina.Tenants.Migrator do
  @moduledoc """
  Runs the per-tenant migrations against each tenant's Postgres schema.

  All tenants share the single `Florina.Repo` connection pool. Isolation is by
  schema: `Ecto.Migrator.run/4` is given `prefix: "tenant_<id>"`, and because the
  baseline migration is pure Ecto DSL (`create table`, `create index`), every
  object lands in that schema. The migrator keeps a per-schema `schema_migrations`
  table, so each tenant tracks its own applied versions independently.
  """
  alias Florina.Tenants

  @doc "Migrate every registered tenant's schema."
  def migrate_all do
    for tenant <- Tenants.list(), do: migrate_one(tenant)
    :ok
  end

  @doc "Migrate a single tenant's schema."
  def migrate_one(%Tenants.Tenant{} = tenant) do
    Ecto.Migrator.run(Florina.Repo, path(), :up,
      all: true,
      prefix: Tenants.schema_prefix(tenant)
    )
  end

  defp path, do: Path.join([:code.priv_dir(:florina), "tenant_repo", "migrations"])
end
