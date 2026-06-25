defmodule Florina.Workers.CalendarSyncScheduler do
  @moduledoc """
  Periodic cron worker — fans out `CalendarSync` to every active tenant.

  Runs every 30 minutes. Mirrors Django's `sync_all_user_calendars` /
  `detect_visits_task` APScheduler jobs.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 3

  require Logger

  alias Florina.Tenants
  alias Florina.Workers.CalendarSync

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tenants = Tenants.list()
    Logger.info("[CalendarSyncScheduler] fanning out to #{length(tenants)} tenant(s)")

    for tenant <- tenants do
      %{tenant_slug: tenant.slug}
      |> CalendarSync.new()
      |> Oban.insert()
    end

    :ok
  end
end
