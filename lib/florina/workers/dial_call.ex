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
  # a 5-min window, so two overlapping ScanTenantCalls runs can't both dial. The
  # spaced PRE/POST offsets (30 min apart) are outside this window, so legitimate
  # repeat dials up to the per-phase cap still happen.
  use Oban.Worker,
    queue: :calls,
    max_attempts: 2,
    unique: [period: 300, keys: [:visit_id, :phase, :tenant_slug]]

  require Logger

  import Ecto.Query

  alias Florina.TenantRepo
  alias Florina.Visits.Visit
  alias Florina.Calls.CallAttempt
  alias Florina.Workers.{Tenant, ScanTenantCalls}
  alias Florina.Services.Assembler

  @max_call_attempts_per_phase 2

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

  defp do_dial(visit, phase, _tenant_slug) do
    # Idempotency: skip if a blocking attempt already exists
    if active_attempt_exists?(visit.id, phase) do
      Logger.info(
        "[DialCall] visit=#{visit.id} phase=#{phase} already has active/completed attempt — skip"
      )

      :ok
    else
      # Hard cap
      total = ScanTenantCalls.phase_dial_count(visit.id, phase)

      if total >= @max_call_attempts_per_phase do
        Logger.info("[DialCall] visit=#{visit.id} phase=#{phase} cap reached (#{total}) — skip")
        :ok
      else
        run_dial(visit, phase)
      end
    end
  end

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
        attempt = create_scheduled_attempt(visit.id, phase)
        fire_call(attempt, phone, prompt, first_message, visit)
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

  defp create_scheduled_attempt(visit_id, phase) do
    {:ok, attempt} =
      %CallAttempt{}
      |> CallAttempt.create_changeset(%{
        visit_id: visit_id,
        phase: phase,
        status: "SCHEDULED"
      })
      |> TenantRepo.insert()

    attempt
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
