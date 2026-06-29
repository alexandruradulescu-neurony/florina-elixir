defmodule Florina.Workers.Tenant do
  @moduledoc """
  Shared helper for Oban workers that operate on per-tenant data.

  Usage at the top of `perform/1`:

      slug = args["tenant_slug"]
      Florina.Workers.Tenant.pin!(slug)

  Pins the per-tenant schema prefix (`Process.put(:tenant_prefix, "tenant_<id>")`)
  so all subsequent `TenantRepo.*` calls land on that tenant's schema. Raises
  `RuntimeError` when the slug is unknown — Oban will retry the job.
  """

  alias Florina.Tenants

  @doc """
  Resolve `slug` and pin the tenant's schema prefix for the current process.
  Returns `:ok` on success, raises when the slug is unknown.
  """
  def pin!(slug) when is_binary(slug) do
    case Tenants.get_by_slug(slug) do
      nil ->
        raise "Workers.Tenant.pin!/1 — unknown tenant #{inspect(slug)}"

      tenant ->
        Process.put(:tenant_prefix, Tenants.schema_prefix(tenant))
        Logger.metadata(tenant: tenant.slug)
        :ok
    end
  end

  @doc """
  For operational (non-provisioning) workers: pin the tenant ONLY if it is
  currently accessible (`Tenants.accessible?/1` — `active: true` AND
  `status: "active"`). Returns `:ok` when pinned, or `:skip` when the tenant is
  no longer accessible (e.g. deactivated/failed between job enqueue and
  execution) so the worker can no-op instead of acting on a disabled tenant.
  Provisioning uses `pin!/1` directly and is exempt.
  """
  def pin_active(slug) when is_binary(slug) do
    if Tenants.accessible?(slug) do
      pin!(slug)
      :ok
    else
      :skip
    end
  end
end
