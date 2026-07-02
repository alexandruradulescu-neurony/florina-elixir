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

  alias Florina.Workers.{ScanTenantCalls, TenantFanOut}

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: TenantFanOut.fan_out(ScanTenantCalls, "CallScheduler")
end
