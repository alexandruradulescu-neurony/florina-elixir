defmodule Florina.Workers.CrmSync do
  @moduledoc """
  Per-tenant CRM (Pipedrive) → local Client sync.

  Pins the tenant DB and delegates to
  `Florina.Integrations.ClientSync.sync_all/0`.

  Mirrors Django's `sync_all_clients_task` in `tasks.py`.

  Args required: `tenant_slug`.
  """
  use Oban.Worker, queue: :sync, max_attempts: 3

  require Logger

  alias Florina.Integrations.ClientSync
  alias Florina.Workers.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug}}) do
    with :ok <- Tenant.pin_active(slug) do
      case ClientSync.sync_all() do
        {:ok, %{created: c, updated: u, errors: errors}} ->
          Logger.info(
            "[CrmSync] tenant=#{slug} created=#{c} updated=#{u} errors=#{length(errors)}"
          )

          if errors != [] do
            Logger.warning("[CrmSync] tenant=#{slug} sync errors: #{inspect(errors)}")
          end

          :ok

        {:error, reason} ->
          Logger.error("[CrmSync] tenant=#{slug} sync failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :skip ->
        Logger.info("[CrmSync] tenant=#{slug} not active — skipping")
        :ok
    end
  end
end
