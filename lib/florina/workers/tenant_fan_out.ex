defmodule Florina.Workers.TenantFanOut do
  @moduledoc """
  Shared fan-out for the periodic cron schedulers: enumerate every active tenant
  and enqueue one child job per tenant. Each scheduler is a thin wrapper around
  `fan_out/2`; the per-tenant timing/work lives in the child worker.
  """
  require Logger

  alias Florina.Tenants

  @doc """
  Enqueue `child_worker` once per active tenant with `%{tenant_slug: slug}` args.
  `log_tag` names the scheduler in log lines. Always returns `:ok` (a periodic
  cron job); an enqueue failure for one tenant is logged and never blocks the rest.
  """
  def fan_out(child_worker, log_tag) when is_atom(child_worker) and is_binary(log_tag) do
    tenants = Tenants.list_active()
    Logger.info("[#{log_tag}] fanning out to #{length(tenants)} active tenant(s)")

    for tenant <- tenants do
      case %{tenant_slug: tenant.slug} |> child_worker.new() |> Oban.insert() do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[#{log_tag}] failed to enqueue #{inspect(child_worker)} for tenant=#{tenant.slug}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end
end
