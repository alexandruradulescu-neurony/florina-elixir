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
end
