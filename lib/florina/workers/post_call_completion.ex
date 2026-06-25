defmodule Florina.Workers.PostCallCompletion do
  @moduledoc """
  Post-call completion handler — enqueued when a post-call ElevenLabs
  conversation finishes (typically triggered from the webhook controller).

  Steps (mirrors Django `process_visit_post_call_completion`):
    1. Pin the tenant DB.
    2. Fetch the `CallAttempt` with its `Visit` and `Client`.
    3. Run `VisitPipeline.process_post_call/3` with the call's transcript.
       This assembles the post-call prompt, distills lessons, and advances
       `visit.status` to `:POST_CALL_DONE`.
    4. Mark `visit.status` as `:COMPLETE` (the pipeline sets `:POST_CALL_DONE`
       which represents the debrief call itself being done; COMPLETE signals
       the whole workflow is done).

  Lessons distillation and CRM push are handled inside `VisitPipeline`
  / `Lessons.distill`. Failures in those steps are logged but do NOT
  propagate — the post-call itself is the user-visible success event.

  Args required: `call_attempt_id`, `tenant_slug`.
  """
  # Oban-unique per (call_attempt_id, tenant) for an hour so the webhook path and
  # the polling fallback can't both run the post-call pipeline for one call.
  use Oban.Worker,
    queue: :calls,
    max_attempts: 3,
    unique: [period: 3600, keys: [:call_attempt_id, :tenant_slug]]

  require Logger

  alias Florina.TenantRepo
  alias Florina.Calls.CallAttempt
  alias Florina.Visits
  alias Florina.Services.VisitPipeline
  alias Florina.Workers.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"call_attempt_id" => ca_id, "tenant_slug" => slug}}) do
    Tenant.pin!(slug)

    case TenantRepo.get(CallAttempt, ca_id) do
      nil ->
        Logger.error("[PostCallCompletion] CallAttempt #{ca_id} not found")
        :ok

      %CallAttempt{visit_id: nil} ->
        Logger.warning("[PostCallCompletion] CallAttempt #{ca_id} has no associated visit — skip")
        :ok

      %CallAttempt{} = ca ->
        handle_completion(ca)
    end
  end

  defp handle_completion(%CallAttempt{visit_id: visit_id, transcript: transcript} = _ca) do
    case Visits.get_with_associations(visit_id) do
      nil ->
        Logger.error("[PostCallCompletion] Visit #{visit_id} not found")
        :ok

      %{status: :COMPLETE} = visit ->
        Logger.info(
          "[PostCallCompletion] visit=#{visit.id} already COMPLETE — skipping reprocess"
        )

        :ok

      visit ->
        transcript_text = transcript || ""

        case VisitPipeline.process_post_call(visit, transcript_text, :END_OF_MEETING) do
          {:ok, %{visit: updated_visit}} ->
            # Mark fully COMPLETE once the post-call pipeline finishes
            if updated_visit.status in [:POST_CALL_DONE, :PRE_CALL_DONE, :IN_PROGRESS, :PLANNED] do
              case Visits.update(updated_visit, %{status: :COMPLETE}) do
                {:ok, _v} ->
                  Logger.info("[PostCallCompletion] visit=#{visit.id} marked COMPLETE")

                {:error, cs} ->
                  Logger.warning(
                    "[PostCallCompletion] could not mark COMPLETE for visit=#{visit.id}: #{inspect(cs.errors)}"
                  )
              end
            end

            :ok

          {:error, reason} ->
            Logger.error(
              "[PostCallCompletion] process_post_call failed for visit=#{visit.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end
end
