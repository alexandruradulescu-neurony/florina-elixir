defmodule Florina.Workers.SyncPendingCallsScheduler do
  @moduledoc """
  Periodic cron worker — fans out `SyncPendingCalls` to every active tenant.

  Runs every 15 minutes. Mirrors Django's `sync_pending_calls` APScheduler job.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 3

  require Logger

  alias Florina.Tenants
  alias Florina.Workers.SyncPendingCalls

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tenants = Tenants.list_active()
    Logger.info("[SyncPendingCallsScheduler] fanning out to #{length(tenants)} active tenant(s)")

    for tenant <- tenants do
      %{tenant_slug: tenant.slug}
      |> SyncPendingCalls.new()
      |> Oban.insert()
    end

    :ok
  end
end
