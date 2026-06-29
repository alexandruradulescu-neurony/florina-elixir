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

  @doc """
  Migrate every fully-provisioned tenant's schema, matching the boot migrator's
  semantics: only `active` tenants (a `provisioning`/`failed` tenant may have a
  half-created or absent schema), and `CREATE SCHEMA IF NOT EXISTS` first so the
  migration can never run against a missing schema.
  """
  def migrate_all do
    for tenant <- Tenants.list_active() do
      Florina.Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{Tenants.schema_prefix(tenant)}"))
      migrate_one(tenant)
    end

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
