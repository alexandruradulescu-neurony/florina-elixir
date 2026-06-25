defmodule Florina.Workers.CrmSyncScheduler do
  @moduledoc """
  Periodic cron worker — fans out `CrmSync` to every active tenant.

  Runs daily at midnight UTC. Mirrors Django's `sync_all_clients_task`
  APScheduler job.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 3

  require Logger

  alias Florina.Tenants
  alias Florina.Workers.CrmSync

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tenants = Tenants.list()
    Logger.info("[CrmSyncScheduler] fanning out to #{length(tenants)} tenant(s)")

    for tenant <- tenants do
      %{tenant_slug: tenant.slug}
      |> CrmSync.new()
      |> Oban.insert()
    end

    :ok
  end
end
