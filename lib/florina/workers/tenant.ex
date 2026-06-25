defmodule Florina.Workers.Tenant do
  @moduledoc """
  Shared helper for Oban workers that operate on per-tenant data.

  Usage at the top of `perform/1`:

      slug = args["tenant_slug"]
      Florina.Workers.Tenant.pin!(slug)

  Pins the per-tenant dynamic repo so all subsequent `TenantRepo.*` calls
  land on that tenant's database. Raises `RuntimeError` when the slug is
  unknown or the connection pool cannot be started — Oban will retry the job.
  """

  @doc """
  Resolve `slug` via the ConnectionManager and pin the TenantRepo for the
  current process. Returns `:ok` on success, raises on failure.
  """
  def pin!(slug) when is_binary(slug) do
    case Florina.Tenants.ConnectionManager.ensure_started(slug) do
      {:ok, pid} ->
        Florina.TenantRepo.put_dynamic_repo(pid)
        :ok

      {:error, reason} ->
        raise "Workers.Tenant.pin!/1 — could not start tenant #{inspect(slug)}: #{inspect(reason)}"
    end
  end

  @doc """
  For operational (non-provisioning) workers: pin the tenant ONLY if it is
  currently accessible (`Tenants.accessible?/1` — `active: true` AND
  `status: "active"`). Returns `:ok` when pinned, or `:skip` when the tenant is
  no longer accessible (e.g. deactivated/failed between job enqueue and
  execution) so the worker can no-op instead of acting on a disabled tenant.
  Raises only if an accessible tenant's pool cannot start (genuine infra
  failure → Oban retry). Provisioning uses `pin!/1` directly and is exempt.
  """
  def pin_active(slug) when is_binary(slug) do
    if Florina.Tenants.accessible?(slug) do
      pin!(slug)
      :ok
    else
      :skip
    end
  end
end
