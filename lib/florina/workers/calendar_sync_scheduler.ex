defmodule Florina.Workers.CalendarSyncScheduler do
  @moduledoc """
  Periodic cron worker — fans out `CalendarSync` to every active tenant.

  Runs every 5 minutes so meeting changes (new/moved/cancelled) surface in the
  app within minutes. Mirrors Django's `sync_all_user_calendars` /
  `detect_visits_task` APScheduler jobs.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 3

  alias Florina.Workers.{CalendarSync, TenantFanOut}

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: TenantFanOut.fan_out(CalendarSync, "CalendarSyncScheduler")
end
