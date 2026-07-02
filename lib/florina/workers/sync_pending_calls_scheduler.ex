defmodule Florina.Workers.SyncPendingCallsScheduler do
  @moduledoc """
  Periodic cron worker — fans out `SyncPendingCalls` to every active tenant.

  Runs every 15 minutes. Mirrors Django's `sync_pending_calls` APScheduler job.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 3

  alias Florina.Workers.{SyncPendingCalls, TenantFanOut}

  @impl Oban.Worker
  def perform(%Oban.Job{}),
    do: TenantFanOut.fan_out(SyncPendingCalls, "SyncPendingCallsScheduler")
end
