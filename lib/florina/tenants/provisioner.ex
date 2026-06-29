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
    #
    # Register as `provisioning`, NOT the schema default `active`: a tenant row
    # is reachable by ResolveTenant the instant it is `active` + status="active",
    # but its schema doesn't exist until the steps below run. Registering active
    # would briefly serve a tenant with no schema (the command-line
    # `Release.provision_tenant` path had exactly this gap — the admin UI already
    # pre-registers as provisioning). We only flip to `active` after the schema
    # is created, migrated, and seeded. `register` is idempotent on slug, so when
    # the admin UI already inserted the provisioning row this is a no-op.
    {:ok, tenant} =
      attrs
      |> Map.put_new(:name, name)
      |> Map.put_new(:status, "provisioning")
      |> Tenants.register()

    prefix = Tenants.schema_prefix(tenant)
    Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))

    Migrator.migrate_one(tenant)

    # seed_tenant must run with the tenant prefix in scope.
    Florina.Tenants.with_prefix(tenant, fn ->
      :ok = Florina.CentralConfig.seed_tenant(slug)
    end)

    # Schema is ready — now it's safe to serve traffic for this tenant.
    {:ok, _} = Tenants.set_status(slug, "active")

    {:ok, Tenants.get_by_slug(slug)}
  end
end
