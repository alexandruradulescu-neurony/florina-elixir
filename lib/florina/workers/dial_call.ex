defmodule Florina.Workers.DialCall do
  @moduledoc """
  Per-visit-phase dialing worker.

  Enqueued by `ScanTenantCalls`. For the given visit + phase:

    1. Pins the tenant DB.
    2. Checks the per-phase attempt cap (MAX_CALL_ATTEMPTS_PER_PHASE = 2).
       Stops immediately if the cap has already been reached.
    3. Checks that a prompt exists for this phase. If not, runs assembly
       first (mirrors Django `process_visit_pre_calls`).
    4. Creates a `CallAttempt` row with status `SCHEDULED`.
    5. Calls `ElevenLabs.initiate_call/4`.
    6. On success: updates the `CallAttempt` with status `INITIATED` and
       the external call_id; advances `visit.status` if appropriate.
    7. On failure: marks the `CallAttempt` as `FAILED`.

  If a SCHEDULED/INITIATED/IN_PROGRESS/COMPLETED attempt already exists for
  this (visit, phase), the job is a no-op — idempotent.

  Args required: `visit_id`, `phase` ("PRE" | "POST"), `tenant_slug`.
  """
  # `unique` dedupes concurrent enqueues of the same (visit, phase, tenant) within
  # this window, so two overlapping ScanTenantCalls runs can't both dial. The window
  # MUST stay shorter than `retry_interval_minutes` (default 5 min) or the legitimate
  # retry — enqueued ~5 min later — would be swallowed as a duplicate of the first.
  use Oban.Worker,
    queue: :calls,
    max_attempts: 2,
    unique: [period: 120, keys: [:visit_id, :phase, :tenant_slug]]

  require Logger

  import Ecto.Query

  alias Florina.TenantRepo
  alias Florina.{OAuth, Visits}
  alias Florina.Visits.Visit
  alias Florina.Calls.CallAttempt
  alias Florina.Integrations.Provider
  alias Florina.Workers.{Tenant, ScanTenantCalls}
  alias Florina.Services.Assembler

  # A calendar-sourced meeting is only worth calling about if "now" is within this
  # window of its (possibly just-moved) start/end time. Guards against calling
  # early/late when a meeting was moved right before the dial.
  @timely_window_seconds 90 * 60

  # Terminal/active statuses — no further dial if one of these exists
  @blocking_statuses ["SCHEDULED", "INITIATED", "IN_PROGRESS", "COMPLETED"]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"visit_id" => visit_id, "phase" => phase, "tenant_slug" => slug}}) do
    with :ok <- Tenant.pin_active(slug) do
      case TenantRepo.get(Visit, visit_id) do
        nil ->
          Logger.warning("[DialCall] visit #{visit_id} not found — discarding job")
          :ok

        visit ->
          visit = TenantRepo.preload(visit, [:agent, :client])
          do_dial(visit, phase, slug)
      end
    else
      :skip ->
        Logger.info("[DialCall] tenant=#{slug} not active — skipping")
        :ok
    end
  end

  defp do_dial(%Visit{status: status} = visit, phase, _tenant_slug)
       when status in [:CANCELLED, :MISSED, :COMPLETE] do
    Logger.info("[DialCall] visit=#{visit.id} phase=#{phase} status=#{status} terminal — skip")
    :ok
  end

  defp do_dial(visit, phase, _tenant_slug) do
    case check_calendar_freshness(visit, phase) do
      :cancelled ->
        Logger.info(
          "[DialCall] visit=#{visit.id} #{phase} aborted — meeting cancelled/removed on calendar"
        )

        :ok

      :mistimed ->
        Logger.info(
          "[DialCall] visit=#{visit.id} #{phase} skipped — meeting moved out of the call window"
        )

        :ok

      {:ok, visit} ->
        cond do
          # Idempotency: skip if a blocking attempt already exists
          active_attempt_exists?(visit.id, phase) ->
            Logger.info(
              "[DialCall] visit=#{visit.id} phase=#{phase} already has active/completed attempt — skip"
            )

            :ok

          # Hard cap
          ScanTenantCalls.phase_dial_count(visit.id, phase) >=
              Florina.Settings.get().max_call_attempts_per_phase ->
            Logger.info("[DialCall] visit=#{visit.id} phase=#{phase} cap reached — skip")
            :ok

          true ->
            run_dial(visit, phase)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Just-before-dial calendar freshness check (sync fix 2/3)
  #
  # Confirms a calendar-sourced meeting still exists and is still timely right
  # before we dial, catching last-minute cancellations/moves the 30-min sync
  # poll would miss. Manual visits (no event id) and unverifiable cases proceed.
  # ---------------------------------------------------------------------------

  defp check_calendar_freshness(%Visit{calendar_event_id: id} = visit, _phase)
       when id in [nil, ""],
       do: {:ok, visit}

  defp check_calendar_freshness(%Visit{} = visit, phase) do
    case credential_for(visit) do
      nil ->
        {:ok, visit}

      cred ->
        case Provider.for_credential(cred).get_event(cred, visit.calendar_event_id) do
          {:error, :not_found} ->
            retire_cancelled(visit)
            :cancelled

          {:ok, %{status: "cancelled"}} ->
            retire_cancelled(visit)
            :cancelled

          {:ok, event} ->
            visit = apply_event_changes(visit, event)
            if timely?(visit, phase), do: {:ok, visit}, else: :mistimed

          {:error, _reason} ->
            # Can't verify (transient/auth) — proceed; the sync reconciliation
            # backstop (fix 1/3) still catches cancellations on the next cycle.
            {:ok, visit}
        end
    end
  end

  defp credential_for(%Visit{agent_id: agent_id, provider: provider}) do
    agent_id
    |> OAuth.list_calendar_credentials_for_user()
    |> Enum.find(fn c -> c.provider == provider end)
  end

  defp retire_cancelled(visit) do
    case Visits.update(visit, %{status: :CANCELLED}) do
      {:ok, _} ->
        :ok

      {:error, cs} ->
        Logger.warning("[DialCall] failed to cancel visit=#{visit.id}: #{inspect(cs.errors)}")
    end
  end

  defp apply_event_changes(visit, event) do
    changes =
      %{}
      |> put_if_changed(:start_time, visit.start_time, Map.get(event, :start_time))
      |> put_if_changed(:end_time, visit.end_time, Map.get(event, :end_time))
      |> put_if_changed(:title, visit.title, Map.get(event, :title))

    if map_size(changes) > 0 do
      case Visits.update(visit, changes) do
        {:ok, v} -> v
        {:error, _cs} -> visit
      end
    else
      visit
    end
  end

  defp put_if_changed(map, key, old, new) when not is_nil(new) and old != new,
    do: Map.put(map, key, new)

  defp put_if_changed(map, _key, _old, _new), do: map

  defp timely?(%Visit{start_time: start}, "PRE") do
    diff = DateTime.diff(start, DateTime.utc_now(), :second)
    diff > 0 and diff <= @timely_window_seconds
  end

  defp timely?(%Visit{end_time: finish}, "POST") do
    diff = DateTime.diff(DateTime.utc_now(), finish, :second)
    diff >= 0 and diff <= @timely_window_seconds
  end

  defp timely?(_visit, _phase), do: true

  defp run_dial(visit, phase) do
    # Ensure assembled prompt exists; assemble on-the-fly if absent.
    # This mirrors Django's inline assemble_pre_call / assemble_post_call calls.
    {prompt, first_message} = resolve_prompt(visit, phase)

    if is_nil(prompt) or String.trim(prompt) == "" do
      Logger.error("[DialCall] visit=#{visit.id} phase=#{phase} no prompt — marking FAILED")
      create_failed_attempt(visit.id, phase)
      :ok
    else
      # Check agent has phone
      phone = get_in(visit, [Access.key(:agent), Access.key(:phone_number)])

      if phone in [nil, ""] do
        Logger.warning("[DialCall] visit=#{visit.id} agent has no phone — skip")
        :ok
      else
        case create_scheduled_attempt_capped(visit.id, phase) do
          {:ok, attempt} ->
            fire_call(attempt, phone, prompt, first_message, visit)

          :cap_reached ->
            Logger.info(
              "[DialCall] visit=#{visit.id} phase=#{phase} cap reached at insert — aborting dial"
            )

            :ok
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Prompt resolution
  # ---------------------------------------------------------------------------

  defp resolve_prompt(visit, "PRE") do
    prompt = visit.pre_call_prompt
    first = visit.pre_call_first_message

    if is_nil(prompt) or String.trim(prompt) == "" do
      # Assemble on the fly (best-effort; errors logged, not raised)
      case Assembler.assemble_pre_call(visit, :SCHEDULED) do
        {:ok, run} when run.success ->
          fresh = TenantRepo.get(Visit, visit.id)
          {fresh.pre_call_prompt, fresh.pre_call_first_message}

        _ ->
          {nil, nil}
      end
    else
      {prompt, first}
    end
  end

  defp resolve_prompt(visit, "POST") do
    prompt = visit.post_call_prompt
    first = visit.post_call_first_message

    if is_nil(prompt) or String.trim(prompt) == "" do
      case Assembler.assemble_post_call(visit, "", :SCHEDULED) do
        {:ok, run} when run.success ->
          fresh = TenantRepo.get(Visit, visit.id)
          {fresh.post_call_prompt, fresh.post_call_first_message}

        _ ->
          {nil, nil}
      end
    else
      {prompt, first}
    end
  end

  defp resolve_prompt(_visit, _phase), do: {nil, nil}

  # ---------------------------------------------------------------------------
  # Dial
  # ---------------------------------------------------------------------------

  defp fire_call(attempt, phone, prompt, first_message, visit) do
    context = %{visit_id: visit.id, call_attempt_id: attempt.id}
    el = Application.get_env(:florina, :elevenlabs_client, Florina.Integrations.ElevenLabs)

    case el.do_initiate_call(phone, prompt, first_message, context) do
      {:ok, %{call_id: call_id}} ->
        {:ok, _updated} =
          attempt
          |> CallAttempt.webhook_changeset(%{status: "INITIATED", external_call_id: call_id})
          |> TenantRepo.update()

        Logger.info(
          "[DialCall] visit=#{visit.id} phase=#{attempt.phase} initiated call_id=#{call_id}"
        )

        # Advance visit status when pre-call fires successfully
        if attempt.phase == "PRE" and visit.status == :PLANNED do
          Florina.Visits.update(visit, %{status: :PRE_CALL_DONE})
        end

        :ok

      {:error, reason} ->
        Logger.error(
          "[DialCall] ElevenLabs error visit=#{visit.id} phase=#{attempt.phase}: #{inspect(reason)}"
        )

        attempt
        |> CallAttempt.webhook_changeset(%{status: "FAILED"})
        |> TenantRepo.update()

        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # CallAttempt helpers
  # ---------------------------------------------------------------------------

  defp active_attempt_exists?(visit_id, phase) do
    TenantRepo.exists?(
      from ca in CallAttempt,
        where:
          ca.visit_id == ^visit_id and ca.phase == ^phase and ca.status in ^@blocking_statuses
    )
  end

  # Cap check + scheduled-attempt insert as one atomic unit. Two dials >120s
  # apart (past the Oban unique window) could otherwise both pass the earlier
  # cap check and exceed the cap. Lock the visit row, re-check the per-phase
  # count inside the txn, and only insert if still under cap.
  defp create_scheduled_attempt_capped(visit_id, phase) do
    cap = Florina.Settings.get().max_call_attempts_per_phase

    result =
      TenantRepo.transaction(fn ->
        from(v in Visit, where: v.id == ^visit_id, lock: "FOR UPDATE")
        |> TenantRepo.one()

        if ScanTenantCalls.phase_dial_count(visit_id, phase) >= cap do
          :cap_reached
        else
          {:ok, attempt} =
            %CallAttempt{}
            |> CallAttempt.create_changeset(%{
              visit_id: visit_id,
              phase: phase,
              status: "SCHEDULED"
            })
            |> TenantRepo.insert()

          {:ok, attempt}
        end
      end)

    case result do
      {:ok, inner} -> inner
      {:error, _reason} -> :cap_reached
    end
  end

  defp create_failed_attempt(visit_id, phase) do
    %CallAttempt{}
    |> CallAttempt.create_changeset(%{
      visit_id: visit_id,
      phase: phase,
      status: "FAILED"
    })
    |> TenantRepo.insert()
  end
end
