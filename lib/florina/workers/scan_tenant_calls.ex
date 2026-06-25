defmodule Florina.Workers.ScanTenantCalls do
  @moduledoc """
  Per-tenant call scheduler.

  Enqueued by `CallScheduler` (cron fan-out). Pins the tenant DB, then scans
  for visits whose pre-call or post-call is due within `SCHEDULER_WINDOW`
  minutes and enqueues a `DialCall` job for each.

  Timing constants (ported from Django `voice/constants.py`):

  - PRE_MEETING_OFFSETS  = [-60, -30]   — 60 and 30 minutes before start
  - POST_MEETING_OFFSETS = [15, 30]     — 15 and 30 minutes after end
  - SCHEDULER_WINDOW     = 10           — ±5 minute tolerance window
  - MAX_CALL_ATTEMPTS_PER_PHASE = 2     — hard cap on total dials per phase

  A visit phase is "due" when `now` is within ±(SCHEDULER_WINDOW / 2) minutes
  of the target time (start_time + offset or end_time + offset).
  A phase is skipped once `total_dials >= MAX_CALL_ATTEMPTS_PER_PHASE`.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Florina.TenantRepo
  alias Florina.Visits.Visit
  alias Florina.Calls.CallAttempt
  alias Florina.Workers.{Tenant, DialCall}

  # Ported from Django voice/constants.py
  @pre_meeting_offsets [-60, -30]
  @post_meeting_offsets [15, 30]
  @scheduler_window_minutes 10
  @max_call_attempts_per_phase 2

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug}}) do
    Tenant.pin!(slug)

    now = DateTime.utc_now()
    half_window = div(@scheduler_window_minutes, 2)

    pre_enqueued = scan_pre_calls(now, half_window, slug)
    post_enqueued = scan_post_calls(now, half_window, slug)

    Logger.info(
      "[ScanTenantCalls] tenant=#{slug} pre=#{pre_enqueued} post=#{post_enqueued} enqueued"
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Pre-call scan
  # ---------------------------------------------------------------------------

  defp scan_pre_calls(now, half_window, tenant_slug) do
    # Visits that could still have a pre-call: status PLANNED or PRE_CALL_DONE
    visits =
      from(v in Visit,
        where: v.status in ^[:PLANNED],
        preload: [:agent]
      )
      |> TenantRepo.all()

    Enum.reduce(visits, 0, fn visit, acc ->
      if phone_missing?(visit),
        do: acc,
        else: enqueue_pre_if_due(visit, now, half_window, tenant_slug, acc)
    end)
  end

  defp enqueue_pre_if_due(visit, now, half_window, tenant_slug, acc) do
    due_times = Enum.map(@pre_meeting_offsets, &DateTime.add(visit.start_time, &1 * 60, :second))

    if Enum.any?(due_times, &within_window?(&1, now, half_window)) do
      total_dials = phase_dial_count(visit.id, "PRE")

      if total_dials >= @max_call_attempts_per_phase do
        Logger.info(
          "[ScanTenantCalls] visit=#{visit.id} PRE cap reached (#{total_dials}), skipping"
        )

        acc
      else
        enqueue_dial(visit.id, "PRE", tenant_slug)
        acc + 1
      end
    else
      acc
    end
  end

  # ---------------------------------------------------------------------------
  # Post-call scan
  # ---------------------------------------------------------------------------

  defp scan_post_calls(now, half_window, tenant_slug) do
    # Visits that have had their pre-call done and meeting has likely ended
    visits =
      from(v in Visit,
        where: v.status in ^[:PRE_CALL_DONE, :IN_PROGRESS],
        preload: [:agent]
      )
      |> TenantRepo.all()

    Enum.reduce(visits, 0, fn visit, acc ->
      if phone_missing?(visit),
        do: acc,
        else: enqueue_post_if_due(visit, now, half_window, tenant_slug, acc)
    end)
  end

  defp enqueue_post_if_due(visit, now, half_window, tenant_slug, acc) do
    due_times = Enum.map(@post_meeting_offsets, &DateTime.add(visit.end_time, &1 * 60, :second))

    if Enum.any?(due_times, &within_window?(&1, now, half_window)) do
      total_dials = phase_dial_count(visit.id, "POST")

      if total_dials >= @max_call_attempts_per_phase do
        Logger.info(
          "[ScanTenantCalls] visit=#{visit.id} POST cap reached (#{total_dials}), skipping"
        )

        acc
      else
        enqueue_dial(visit.id, "POST", tenant_slug)
        acc + 1
      end
    else
      acc
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp within_window?(target, now, half_window_minutes) do
    diff_seconds = abs(DateTime.diff(now, target, :second))
    diff_seconds <= half_window_minutes * 60
  end

  @doc """
  Total dials for a (visit_id, phase) pair.
  Each CallAttempt row counts as 1 (this matches Django's approach after
  dropping `retry_count` — Elixir always creates a new row per attempt).
  """
  def phase_dial_count(visit_id, phase) do
    TenantRepo.aggregate(
      from(ca in CallAttempt, where: ca.visit_id == ^visit_id and ca.phase == ^phase),
      :count
    ) || 0
  end

  defp enqueue_dial(visit_id, phase, tenant_slug) do
    %{visit_id: visit_id, phase: phase, tenant_slug: tenant_slug}
    |> DialCall.new()
    |> Oban.insert()
  end

  defp phone_missing?(%Visit{agent: %{phone_number: nil}}), do: true
  defp phone_missing?(%Visit{agent: %{phone_number: ""}}), do: true
  defp phone_missing?(_), do: false
end
