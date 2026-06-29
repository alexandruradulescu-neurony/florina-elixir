defmodule Florina.Tenants do
  @moduledoc """
  Control-plane registry of tenants. Each tenant's data lives in its own Postgres
  **schema** (`tenant_<id>`) on the single shared database; this module owns the
  registry rows and the schema-prefix helpers every chokepoint pins from.
  """
  import Ecto.Query, only: [from: 2]
  alias Florina.Repo
  alias Florina.Tenants.Tenant

  @doc """
  The Postgres schema name for a tenant: `"tenant_<id>"`. Derived from the
  tenant's immutable id (never the mutable slug), so a slug rename never moves a
  tenant's data.
  """
  def schema_prefix(%Tenant{id: id}) when is_integer(id), do: "tenant_#{id}"

  @doc "Run `fun` with the tenant's schema prefix pinned on the current process."
  def with_prefix(%Tenant{} = tenant, fun) when is_function(fun, 0) do
    previous = Process.get(:tenant_prefix)
    Process.put(:tenant_prefix, schema_prefix(tenant))

    try do
      fun.()
    after
      if previous,
        do: Process.put(:tenant_prefix, previous),
        else: Process.delete(:tenant_prefix)
    end
  end

  def list, do: Repo.all(from t in Tenant, order_by: t.slug)

  @doc "Returns only tenants that are fully provisioned: status == \"active\" AND active == true."
  def list_active,
    do:
      Repo.all(
        from t in Tenant, where: t.status == "active" and t.active == true, order_by: t.slug
      )

  def get_by_slug(slug) when is_binary(slug), do: Repo.get_by(Tenant, slug: slug)
  def get_by_slug(_), do: nil

  @doc """
  True only if the tenant exists, is enabled (`active: true`) AND fully
  provisioned (`status: "active"`). This is the gate for serving any request or
  running any operational background job for a tenant — a `provisioning`/`failed`
  tenant is never reachable even if `active` happens to be true. (Provisioning
  itself uses `Workers.Tenant.pin!/1` directly, so it is exempt.)
  """
  def accessible?(slug) when is_binary(slug) do
    case get_by_slug(slug) do
      %Tenant{active: true, status: "active"} -> true
      _ -> false
    end
  end

  def accessible?(_), do: false

  @doc "Insert a tenant. Idempotent on slug: an existing slug is left unchanged."
  def register(attrs) do
    slug = attrs[:slug] || attrs["slug"]

    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :slug)
    |> case do
      {:ok, _} -> {:ok, get_by_slug(slug)}
      {:error, _} = err -> err
    end
  end

  @doc "Set the status of a tenant (provisioning | active | failed)."
  def set_status(slug, status)
      when is_binary(slug) and status in ~w(provisioning active failed) do
    case get_by_slug(slug) do
      nil ->
        {:error, :not_found}

      tenant ->
        tenant
        |> Tenant.changeset(%{status: status})
        |> Repo.update()
    end
  end

  @doc "Toggle the active flag on a tenant."
  def set_active(slug, active) when is_binary(slug) and is_boolean(active) do
    case get_by_slug(slug) do
      nil ->
        {:error, :not_found}

      tenant ->
        tenant
        |> Tenant.changeset(%{active: active})
        |> Repo.update()
    end
  end

  @doc """
  Activate a tenant, first ensuring its schema exists and any pending per-tenant
  migrations are applied — BEFORE it can serve traffic. Boot migrations skip
  inactive tenants, so a tenant that was deactivated across a deploy (which added
  migrations) would otherwise be reactivated onto a stale schema. Fail-loud: if
  migration raises, the tenant is left inactive. Migration runs only when
  `:migrate_tenants_on_boot` is set (prod); dev/test just flip the flag, matching
  `BootMigrator`.
  """
  def activate(slug) when is_binary(slug) do
    case get_by_slug(slug) do
      nil ->
        {:error, :not_found}

      tenant ->
        if Application.get_env(:florina, :migrate_tenants_on_boot, false) do
          prefix = schema_prefix(tenant)
          Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))
          Florina.Tenants.Migrator.migrate_one(tenant)
        end

        set_active(slug, true)
    end
  end

  @doc "Replace a tenant's allowed email-domain list."
  def set_allowed_domains(slug, domains) when is_list(domains) do
    case get_by_slug(slug) do
      nil -> {:error, :not_found}
      tenant -> tenant |> Tenant.changeset(%{allowed_email_domains: domains}) |> Repo.update()
    end
  end
end
