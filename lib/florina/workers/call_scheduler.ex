defmodule Florina.Workers.CallScheduler do
  @moduledoc """
  Periodic cron worker — the global fan-out entry point for the call scheduler.

  Runs every 5 minutes (configured via `Oban.Plugins.Cron` in config.exs).
  Enumerates all active tenants and enqueues one `ScanTenantCalls` job per
  tenant. The actual timing logic lives in `ScanTenantCalls`.

  Mirrors the APScheduler-registered `process_visit_pre_calls` /
  `process_visit_post_calls` cycle in Django's `tasks.py`.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 3

  require Logger

  alias Florina.Tenants
  alias Florina.Workers.ScanTenantCalls

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tenants = Tenants.list()

    Logger.info("[CallScheduler] fanning out to #{length(tenants)} tenant(s)")

    for tenant <- tenants do
      %{tenant_slug: tenant.slug}
      |> ScanTenantCalls.new()
      |> Oban.insert()
    end

    :ok
  end
end
