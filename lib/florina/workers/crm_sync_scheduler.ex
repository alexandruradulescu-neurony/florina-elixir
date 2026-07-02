defmodule Florina.Workers.CrmSyncScheduler do
  @moduledoc """
  Periodic cron worker — fans out `CrmSync` to every active tenant.

  Runs daily at midnight UTC. Mirrors Django's `sync_all_clients_task`
  APScheduler job.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 3

  alias Florina.Workers.{CrmSync, TenantFanOut}

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: TenantFanOut.fan_out(CrmSync, "CrmSyncScheduler")
end
