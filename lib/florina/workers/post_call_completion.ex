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
    5. Push the debrief summary back to the client's CRM deal as a note and set
       `visit.crm_synced` (best-effort, Pipedrive only for now).

  Lessons distillation is handled inside `VisitPipeline` / `Lessons.distill`.
  The CRM push and lessons are best-effort: failures are logged but do NOT
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
  alias Florina.Integrations.CRM
  alias Florina.Visits
  alias Florina.Services.VisitPipeline
  alias Florina.Workers.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"call_attempt_id" => ca_id, "tenant_slug" => slug}}) do
    with :ok <- Tenant.pin_active(slug) do
      case TenantRepo.get(CallAttempt, ca_id) do
        nil ->
          Logger.error("[PostCallCompletion] CallAttempt #{ca_id} not found")
          :ok

        %CallAttempt{visit_id: nil} ->
          Logger.warning(
            "[PostCallCompletion] CallAttempt #{ca_id} has no associated visit — skip"
          )

          :ok

        %CallAttempt{} = ca ->
          handle_completion(ca)
      end
    else
      :skip ->
        Logger.info("[PostCallCompletion] tenant=#{slug} not active — skipping")
        :ok
    end
  end

  defp handle_completion(%CallAttempt{
         visit_id: visit_id,
         transcript: transcript,
         summary: summary
       }) do
    case Visits.get_with_associations(visit_id) do
      nil ->
        Logger.error("[PostCallCompletion] Visit #{visit_id} not found")
        :ok

      %{status: :COMPLETE} = visit ->
        # Already fully processed — don't re-run the pipeline. But a CRM push that
        # failed on a prior run leaves crm_synced false, so give it one more
        # best-effort try (maybe_sync_crm is a no-op once crm_synced is true).
        Logger.info("[PostCallCompletion] visit=#{visit.id} already COMPLETE — retrying CRM only")
        maybe_sync_crm(visit)
        :ok

      visit ->
        # Persist the debrief summary the webhook captured (CallAttempt.summary)
        # onto the visit so lessons distillation — which gates on
        # Visit.post_call_summary — actually runs. Nothing else writes this field.
        visit = store_post_call_summary(visit, summary)
        transcript_text = transcript || ""

        case VisitPipeline.process_post_call(visit, transcript_text, :END_OF_MEETING) do
          {:ok, %{run: run, visit: updated_visit}} ->
            # Only mark fully COMPLETE when the post-call generation actually
            # succeeded. A failed run (LLM/parse/validation error) must leave the
            # visit in its prior status so it can be retried/inspected, not be
            # silently stamped done.
            if run.success and
                 updated_visit.status in [
                   :POST_CALL_DONE,
                   :PRE_CALL_DONE,
                   :IN_PROGRESS,
                   :PLANNED,
                   :MISSED,
                   :ARCHIVED
                 ] do
              case Visits.update(updated_visit, %{status: :COMPLETE}) do
                {:ok, _v} ->
                  Logger.info("[PostCallCompletion] visit=#{visit.id} marked COMPLETE")

                {:error, cs} ->
                  Logger.warning(
                    "[PostCallCompletion] could not mark COMPLETE for visit=#{visit.id}: #{inspect(cs.errors)}"
                  )
              end
            else
              unless run.success do
                Logger.warning(
                  "[PostCallCompletion] post-call generation failed for visit=#{visit.id} — leaving status=#{updated_visit.status}, not marking COMPLETE"
                )
              end
            end

            # Best-effort: push the debrief summary to the client's CRM deal. This
            # is independent of the prompt-generation run above — the summary (from
            # the call itself) is the payload, so it ships even if generation failed.
            # updated_visit already carries the stored summary + crm_deal_id.
            maybe_sync_crm(updated_visit)

            :ok

          {:error, reason} ->
            Logger.error(
              "[PostCallCompletion] process_post_call failed for visit=#{visit.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp store_post_call_summary(visit, summary) when is_binary(summary) and summary != "" do
    case Visits.update(visit, %{post_call_summary: summary}) do
      {:ok, v} ->
        v

      {:error, cs} ->
        Logger.warning(
          "[PostCallCompletion] could not store post_call_summary for visit=#{visit.id}: " <>
            inspect(cs.errors)
        )

        visit
    end
  end

  defp store_post_call_summary(visit, _summary), do: visit

  # Push the debrief summary to the client's CRM deal as a note, then flag the
  # visit crm_synced. Guards: only when there's a deal to attach to AND a summary
  # to send, and never twice. Any CRM error is logged and swallowed — the CRM push
  # is a side effect, never a gate on the post-call's success.
  defp maybe_sync_crm(%{crm_synced: true}), do: :ok

  defp maybe_sync_crm(%{crm_deal_id: deal_id, post_call_summary: summary} = visit)
       when is_binary(deal_id) and deal_id != "" and is_binary(summary) and summary != "" do
    subject = "Florina post-call debrief — " <> (visit.title || "meeting")

    case CRM.create_note(deal_id, summary, subject) do
      {:ok, _note} ->
        case Visits.update(visit, %{crm_synced: true}) do
          {:ok, _v} ->
            Logger.info(
              "[PostCallCompletion] visit=#{visit.id} debrief pushed to CRM deal=#{deal_id}"
            )

          {:error, cs} ->
            Logger.warning(
              "[PostCallCompletion] CRM note sent but crm_synced not set for visit=#{visit.id}: #{inspect(cs.errors)}"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "[PostCallCompletion] CRM push failed for visit=#{visit.id} deal=#{deal_id}: #{inspect(reason)}"
        )
    end

    :ok
  end

  defp maybe_sync_crm(_visit), do: :ok
end
