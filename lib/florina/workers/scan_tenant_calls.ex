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
  # Unique per tenant within a window shorter than the 5-min cron cadence.
  use Oban.Worker, queue: :scheduler, max_attempts: 3, unique: [period: 120, keys: [:tenant_slug]]

  require Logger

  import Ecto.Query

  alias Florina.TenantRepo
  alias Florina.Visits.Visit
  alias Florina.Calls.CallAttempt
  alias Florina.Workers.{Tenant, DialCall}
  alias Florina.Settings

  # Retry model (all tenant-configurable via GlobalSettings):
  #   first attempt at <phase>_call_offset_minutes, then every
  #   retry_interval_minutes, up to max_call_attempts_per_phase.
  @scheduler_window_minutes 10

  # A meeting whose end time is more than this many minutes in the past and was
  # never handled (no calls completed) is retired to :MISSED so it stops looking
  # "Planned" forever. Comfortably past the post-call offsets (+15/+30) + retries.
  @missed_grace_minutes 120

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug}}) do
    with :ok <- Tenant.pin_active(slug) do
      now = DateTime.utc_now()
      half_window = div(@scheduler_window_minutes, 2)
      settings = Settings.get()

      pre_enqueued = scan_pre_calls(now, half_window, slug, settings)
      post_enqueued = scan_post_calls(now, half_window, slug, settings)
      missed = mark_missed(now)

      Logger.info(
        "[ScanTenantCalls] tenant=#{slug} pre=#{pre_enqueued} post=#{post_enqueued} " <>
          "missed=#{missed} enqueued"
      )

      :ok
    else
      :skip ->
        Logger.info("[ScanTenantCalls] tenant=#{slug} not active — skipping")
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Pre-call scan
  # ---------------------------------------------------------------------------

  defp scan_pre_calls(now, half_window, tenant_slug, settings) do
    # Visits that could still have a pre-call: status PLANNED or PRE_CALL_DONE
    visits =
      from(v in Visit,
        where: v.status in ^[:PLANNED] and v.calls_enabled == true,
        preload: [:agent]
      )
      |> TenantRepo.all()

    Enum.reduce(visits, 0, fn visit, acc ->
      if agent_unavailable?(visit),
        do: acc,
        else: enqueue_pre_if_due(visit, now, half_window, tenant_slug, settings, acc)
    end)
  end

  defp enqueue_pre_if_due(visit, now, half_window, tenant_slug, settings, acc) do
    due_times =
      due_times(visit.start_time, settings.pre_call_offset_minutes, settings)

    if Enum.any?(due_times, &within_window?(&1, now, half_window)) do
      total_dials = phase_dial_count(visit.id, "PRE")

      if total_dials >= settings.max_call_attempts_per_phase do
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

  defp scan_post_calls(now, half_window, tenant_slug, settings) do
    # Visits that have had their pre-call done and meeting has likely ended
    visits =
      from(v in Visit,
        where: v.status in ^[:PRE_CALL_DONE, :IN_PROGRESS] and v.calls_enabled == true,
        preload: [:agent]
      )
      |> TenantRepo.all()

    Enum.reduce(visits, 0, fn visit, acc ->
      if agent_unavailable?(visit),
        do: acc,
        else: enqueue_post_if_due(visit, now, half_window, tenant_slug, settings, acc)
    end)
  end

  defp enqueue_post_if_due(visit, now, half_window, tenant_slug, settings, acc) do
    due_times = due_times(visit.end_time, settings.post_call_offset_minutes, settings)

    if Enum.any?(due_times, &within_window?(&1, now, half_window)) do
      total_dials = phase_dial_count(visit.id, "POST")

      if total_dials >= settings.max_call_attempts_per_phase do
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
  # Retire stale meetings
  # ---------------------------------------------------------------------------

  # Mark meetings whose end time is well past and that were never handled
  # (still PLANNED/PRE_CALL_DONE/IN_PROGRESS) as :MISSED, so they drop out of
  # scheduling and the calendar instead of lingering as "Planned" forever.
  defp mark_missed(now) do
    cutoff = DateTime.add(now, -@missed_grace_minutes * 60, :second)
    stamp = DateTime.truncate(now, :second)

    # A visit that was actually called must never be marked MISSED. Exclude any
    # visit that has a CallAttempt that was placed/active/completed (i.e. whose
    # status is NOT a pure FAILED/NO_ANSWER non-call), via a correlated subquery.
    {count, _} =
      from(v in Visit,
        as: :visit,
        where: v.status in ^[:PLANNED, :PRE_CALL_DONE, :IN_PROGRESS] and v.end_time < ^cutoff,
        where:
          not exists(
            from(ca in CallAttempt,
              where:
                ca.visit_id == parent_as(:visit).id and
                  ca.status not in ["FAILED", "NO_ANSWER"]
            )
          )
      )
      |> TenantRepo.update_all(set: [status: :MISSED, updated_at: stamp])

    count
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp within_window?(target, now, half_window_minutes) do
    diff_seconds = abs(DateTime.diff(now, target, :second))
    diff_seconds <= half_window_minutes * 60
  end

  # Attempt times for a phase: first at `offset_min` from `base`, then one every
  # `retry_interval_minutes`, for `max_call_attempts_per_phase` attempts.
  defp due_times(base, offset_min, settings) do
    attempts = max(settings.max_call_attempts_per_phase, 1)
    interval = settings.retry_interval_minutes

    for n <- 0..(attempts - 1)//1 do
      DateTime.add(base, (offset_min + n * interval) * 60, :second)
    end
  end

  @doc """
  Total dials for a (visit_id, phase) pair that count toward the per-phase cap.
  Each CallAttempt row counts as 1. A `NO_ANSWER` is a real placed dial to the
  person, so it consumes an attempt (otherwise unanswered calls would re-dial
  past the cap). `FAILED` is excluded — it's a transient provider error that
  never reached anyone, so it shouldn't burn an attempt.
  """
  def phase_dial_count(visit_id, phase) do
    TenantRepo.aggregate(
      from(ca in CallAttempt,
        where:
          ca.visit_id == ^visit_id and ca.phase == ^phase and
            ca.status not in ["FAILED"]
      ),
      :count
    ) || 0
  end

  defp enqueue_dial(visit_id, phase, tenant_slug) do
    %{visit_id: visit_id, phase: phase, tenant_slug: tenant_slug}
    |> DialCall.new()
    |> Oban.insert()
  end

  # A visit is not dial-eligible if its agent is missing, deactivated, or has no
  # phone — skip enqueueing a DialCall for it at all (DialCall re-checks as a
  # backstop, but this avoids the wasted job + prompt assembly).
  defp agent_unavailable?(%Visit{agent: nil}), do: true
  defp agent_unavailable?(%Visit{agent: %{active: false}}), do: true
  defp agent_unavailable?(%Visit{agent: %{phone_number: phone}}) when phone in [nil, ""], do: true
  defp agent_unavailable?(_), do: false
end
