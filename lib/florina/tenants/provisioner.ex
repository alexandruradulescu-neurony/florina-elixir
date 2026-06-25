defmodule Florina.Tenants.Provisioner do
  @moduledoc """
  Operator-driven onboarding for a tenant in the **schema-per-tenant** model:
  register the tenant in the control plane, create its Postgres schema
  (`tenant_<id>`) on the single shared database, migrate that schema, then seed
  central config into it. Idempotent — safe to run repeatedly.

  There is no per-tenant database or connection pool any more: everything runs
  on `Florina.Repo`, isolated by schema.
  """
  alias Florina.Repo
  alias Florina.Tenants
  alias Florina.Tenants.Migrator

  def provision(%{slug: slug, name: name} = attrs) do
    # Register first so the tenant gets its immutable id; the schema name is
    # derived from that id, never the (mutable) slug.
    {:ok, tenant} = Tenants.register(Map.put_new(attrs, :name, name))

    prefix = Tenants.schema_prefix(tenant)
    Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))

    Migrator.migrate_one(tenant)

    # seed_tenant must run with the tenant prefix in scope.
    Florina.Tenants.with_prefix(tenant, fn ->
      :ok = Florina.CentralConfig.seed_tenant(slug)
    end)

    {:ok, Tenants.get_by_slug(slug)}
  end
end
