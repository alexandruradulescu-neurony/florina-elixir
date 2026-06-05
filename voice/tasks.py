"""
Scheduled tasks for the voice app using APScheduler.
These functions are registered with APScheduler in voice/apps.py.
"""

import logging
from datetime import timedelta

from django.utils import timezone

from .constants import CallPhase, CallStatus, LogLevel
from .models import CallAttempt, User
from .selectors import get_sales_agents
from .services import (
    log_activity,
    sync_call_status_from_api,
    trigger_agent_call,
)

logger = logging.getLogger(__name__)


def _phase_dial_count(*, visit, phase: str) -> int:
    """Total dial attempts for a (visit, phase) target.

    Each `CallAttempt` row represents at least 1 dial; the `retry_count`
    field tracks how many times that row was re-dialed by `retry_failed_call`.
    Total dials = sum of (1 + retry_count) across rows.
    """
    from django.db.models import Sum

    if visit is None:
        return 0
    qs = CallAttempt.objects.filter(visit=visit, phase=phase)
    total = qs.aggregate(total=Sum("retry_count"))["total"] or 0
    return total + qs.count()


def _resolve_prompt_for_call(call_attempt):
    """Return ``(prompt_text, first_message_text)`` for an outbound dial.

    Resolves the prompt from the Visit's assembler output. Returns
    ``(None, None)`` when no usable prompt source exists — the caller must
    mark the CallAttempt as FAILED rather than dialing without an override
    (EL would otherwise fall back to its default greeting, the original
    PR 6 bug symptom).

    PR Y2b: the legacy `VoicePrompt` + Meeting-typed `format_prompt_with_-
    context` fallback was removed alongside the Meeting model. Every
    live CallAttempt is visit-linked and must have its prompt assembled
    via `assemble_pre_call` / `assemble_post_call` before dialing.
    """
    visit = getattr(call_attempt, "visit", None)
    if visit is None:
        return None, None
    if call_attempt.phase == CallPhase.PRE_MEETING:
        body = (visit.pre_call_prompt or "").strip()
        first = (visit.pre_call_first_message or "").strip()
    else:
        body = (visit.post_call_prompt or "").strip()
        first = (visit.post_call_first_message or "").strip()
    if not body:
        logger.warning(
            "CallAttempt %s links to visit %s but the assembled %s prompt is empty.",
            call_attempt.id,
            visit.id,
            "pre-call" if call_attempt.phase == CallPhase.PRE_MEETING else "post-call",
        )
        return None, None
    return body, (first or None)


def sync_google_calendar_for_user(user_id: int):
    """
    Sync Google Calendar for a specific user.

    Args:
        user_id: User ID to sync calendar for
    """
    try:
        user = User.objects.get(id=user_id)

        if not user.is_sales_agent:
            logger.info(f"User {user.username} is not a sales agent, skipping calendar sync")
            return {"success": False, "error": "Not a sales agent"}

        # Sync calendar (session will be None for background tasks - needs to be handled differently)
        # For now, we'll log that sync needs to be done manually or via OAuth
        logger.info(f"Calendar sync requested for user {user_id}")

        # Note: Calendar sync requires user's OAuth session, which may not be available in background tasks
        # This task should be called from a view where session is available, or we need to store credentials
        log_activity(user=user, action="Calendar sync task triggered", details={"user_id": user_id})

        return {"success": True, "message": "Sync task triggered"}

    except User.DoesNotExist:
        logger.error(f"User {user_id} not found")
        return {"success": False, "error": "User not found"}
    except Exception as e:
        logger.error(f"Error syncing calendar for user {user_id}: {e}", exc_info=True)
        log_activity(
            action="Calendar sync task failed",
            details={"user_id": user_id, "error": str(e)},
            level=LogLevel.ERROR,
        )
        raise


def sync_all_user_calendars():
    """
    Sync Google Calendar for all sales agents.
    Runs periodically via APScheduler.
    Now works with database-stored credentials!
    Syncs today's meetings (start of day to end of day in UTC).
    """
    try:
        from datetime import datetime, time

        from .services import sync_google_calendar

        agents = get_sales_agents()
        synced_count = 0
        errors = []

        # Sync today's meetings (start of day to end of day in UTC)
        now = timezone.now()
        today_start = timezone.make_aware(datetime.combine(now.date(), time.min))
        today_end = timezone.make_aware(datetime.combine(now.date(), time.max))

        for agent in agents:
            try:
                # Sync calendar (no session needed - uses database credentials)
                results = sync_google_calendar(
                    user=agent,
                    time_min=today_start,
                    time_max=today_end,
                    session=None,  # Background task - no session
                )

                if results.get("errors"):
                    errors.extend([f"{agent.username}: {err}" for err in results["errors"]])

                synced_count += 1

                log_activity(user=agent, action="Calendar sync completed", details=results)

            except Exception as e:
                error_msg = f"Error syncing calendar for {agent.username}: {str(e)}"
                logger.error(error_msg, exc_info=True)
                errors.append(error_msg)
                log_activity(
                    user=agent,
                    action="Calendar sync failed",
                    details={"error": str(e)},
                    level=LogLevel.ERROR,
                )

        logger.info(f"Calendar sync completed: {synced_count} agents synced, {len(errors)} errors")

        return {"synced_count": synced_count, "errors": errors}

    except Exception as e:
        logger.error(f"Error in sync_all_user_calendars: {e}", exc_info=True)
        log_activity(
            action="Calendar sync task failed", details={"error": str(e)}, level=LogLevel.ERROR
        )
        raise


def sync_pending_calls():
    """
    Periodic task to sync call status from ElevenLabs API for calls that haven't been updated.
    Runs every 15 minutes to check for calls that are still in progress.
    """

    from django.utils import timezone

    from .constants import CallStatus
    from .models import CallAttempt

    logger.info("Starting pending calls sync task")

    try:
        # Find calls that are still in progress and were initiated more than 5 minutes ago
        # (calls should complete within a few minutes)
        cutoff_time = timezone.now() - timedelta(minutes=5)

        pending_calls = CallAttempt.objects.filter(
            status__in=[CallStatus.INITIATED, CallStatus.IN_PROGRESS, CallStatus.SCHEDULED],
            external_call_id__isnull=False,
            executed_at__lt=cutoff_time,
        )

        synced_count = 0
        for call_attempt in pending_calls:
            try:
                if sync_call_status_from_api(call_attempt):
                    synced_count += 1
            except Exception as e:
                logger.error(f"Error syncing call {call_attempt.id}: {e}", exc_info=True)

        logger.info(
            f"Pending calls sync completed: {synced_count} calls synced out of {pending_calls.count()}"
        )

        return {"synced_count": synced_count, "total_pending": pending_calls.count()}

    except Exception as e:
        logger.error(f"Error in sync_pending_calls: {e}", exc_info=True)
        log_activity(
            action="Pending calls sync task failed", details={"error": str(e)}, level=LogLevel.ERROR
        )
        raise


# ============================================================================
# New Visit-based tasks
# ============================================================================


def sync_all_clients_task():
    """
    Periodic task: sync all clients from CRM into local Client model.
    Runs daily (overnight).
    """
    from .services.client_sync import sync_all_clients

    try:
        results = sync_all_clients()
        logger.info(
            f"Client sync: {results['created']} created, "
            f"{results['updated']} updated, "
            f"{len(results['errors'])} errors"
        )
        return results
    except Exception as e:
        logger.error(f"Error in sync_all_clients_task: {e}", exc_info=True)
        log_activity(
            action="Client sync task failed",
            details={"error": str(e)},
            level=LogLevel.ERROR,
        )
        raise


def detect_visits_task():
    """
    Periodic task: scan all agents' calendars for today and create Visits
    for events matching known clients.
    Runs every 30 minutes alongside calendar sync.
    """
    from .services.visit_pipeline import detect_visits_for_all_agents

    try:
        results = detect_visits_for_all_agents()
        logger.info(
            f"Visit detection: {results['total_created']} created, "
            f"{results['total_updated']} updated, "
            f"{results['total_skipped']} skipped"
        )
        return results
    except Exception as e:
        logger.error(f"Error in detect_visits_task: {e}", exc_info=True)
        log_activity(
            action="Visit detection task failed",
            details={"error": str(e)},
            level=LogLevel.ERROR,
        )
        raise


def process_visit_pre_calls():
    """
    Periodic task: find visits needing pre-calls, generate prompts, trigger calls.
    Runs every 5 minutes (same cadence as check_and_trigger_calls).

    Flow per visit:
      1. Enrich client data from CRM (fresh pull)
      2. Generate voice prompt via LLM (meta-prompt + context)
      3. Trigger ElevenLabs call with generated prompt
      4. Update visit status
    """
    from .constants import MAX_CALL_ATTEMPTS_PER_PHASE, VisitStatus
    from .models import CallAttempt, GenerationRun, GlobalSettings
    from .selectors import get_visits_needing_pre_call
    from .services.assembler import assemble_pre_call
    from .services.client_sync import enrich_client_from_crm

    try:
        visits = get_visits_needing_pre_call()
        triggered = 0

        for visit in visits:
            try:
                # Skip if agent has no phone
                if not visit.agent.phone_number:
                    logger.warning(
                        f"Agent {visit.agent.username} has no phone, skipping visit {visit.id}"
                    )
                    continue

                # Skip if already has a scheduled/active pre-call
                existing = CallAttempt.objects.filter(
                    visit=visit,
                    phase=CallPhase.PRE_MEETING,
                    status__in=[
                        CallStatus.SCHEDULED,
                        CallStatus.INITIATED,
                        CallStatus.IN_PROGRESS,
                        CallStatus.COMPLETED,
                    ],
                ).exists()
                if existing:
                    continue

                # PR 6 hard cap: count total dials (initial + retries) and
                # bail once the cap is reached. Counting dials (not just rows)
                # is essential because `retry_failed_call` reuses rows.
                total_dials = _phase_dial_count(visit=visit, phase=CallPhase.PRE_MEETING)
                if total_dials >= MAX_CALL_ATTEMPTS_PER_PHASE:
                    logger.info(
                        "Visit %s pre-call cap reached (%d/%d dials) — no new attempt.",
                        visit.id,
                        total_dials,
                        MAX_CALL_ATTEMPTS_PER_PHASE,
                    )
                    continue

                # Enrich client data
                enrich_client_from_crm(visit.client)

                # Auto-assemble pre-call prompt via the assembler service.
                # The assembler logs an audit row to GenerationRun and respects
                # per-field locks on the Visit. We trigger with SCHEDULED so
                # the audit row records this run came from the scheduled job.
                settings = GlobalSettings.load()
                run = assemble_pre_call(
                    visit,
                    triggered_by=GenerationRun.TriggeredBy.SCHEDULED,
                )
                if not run.success:
                    logger.error(
                        "Failed to generate pre-call prompt for visit %s: %s",
                        visit.id,
                        run.error,
                    )
                    continue
                # Re-read from DB in case lock state changed mid-run.
                visit.refresh_from_db()
                prompt = visit.pre_call_prompt
                if not prompt:
                    logger.error(
                        "Pre-call prompt empty after assembly for visit %s "
                        "(likely both fields locked)",
                        visit.id,
                    )
                    continue

                # Create CallAttempt
                call = CallAttempt.objects.create(
                    visit=visit,
                    phase=CallPhase.PRE_MEETING,
                    scheduled_offset_minutes=settings.pre_call_offset_minutes,
                    status=CallStatus.SCHEDULED,
                    scheduled_time=timezone.now(),
                )

                # Trigger the call. PR 6: pass `visit.pre_call_first_message`
                # (was hardcoded `None` — the assembler's first-message output
                # was being dropped, so EL fell back to its default greeting
                # for the agent.)
                result = trigger_agent_call(
                    agent_phone=visit.agent.phone_number,
                    prompt_text=prompt,
                    context_data={"visit_id": visit.id, "client": visit.client.name},
                    call_attempt=call,
                    first_message_text=visit.pre_call_first_message or None,
                )

                if result.get("success"):
                    visit.status = VisitStatus.PRE_CALL_DONE
                    visit.save(update_fields=["status", "updated_at"])
                    triggered += 1
                else:
                    logger.error(
                        f"Pre-call trigger failed for visit {visit.id}: {result.get('error')}"
                    )

            except Exception as e:
                logger.error(f"Error processing pre-call for visit {visit.id}: {e}", exc_info=True)

        if triggered:
            logger.info(f"Visit pre-calls: {triggered} triggered")
        return {"triggered": triggered}

    except Exception as e:
        logger.error(f"Error in process_visit_pre_calls: {e}", exc_info=True)
        raise


def process_visit_post_calls():
    """
    Periodic task: find visits needing post-calls, generate prompts, trigger calls.
    Runs every 5 minutes.

    Flow per visit:
      1. Generate post-call voice prompt via LLM
      2. Trigger ElevenLabs call
      3. (After call completes via webhook): summarize transcript, push to CRM
    """
    from .constants import MAX_CALL_ATTEMPTS_PER_PHASE, VisitStatus
    from .models import CallAttempt, GenerationRun, GlobalSettings
    from .selectors import get_visits_needing_post_call
    from .services.assembler import assemble_post_call

    try:
        visits = get_visits_needing_post_call()
        triggered = 0

        for visit in visits:
            try:
                if not visit.agent.phone_number:
                    continue

                # Skip if already has a scheduled/active post-call
                existing = CallAttempt.objects.filter(
                    visit=visit,
                    phase=CallPhase.POST_MEETING,
                    status__in=[
                        CallStatus.SCHEDULED,
                        CallStatus.INITIATED,
                        CallStatus.IN_PROGRESS,
                        CallStatus.COMPLETED,
                    ],
                ).exists()
                if existing:
                    continue

                # PR 6 hard cap — see process_visit_pre_calls for rationale.
                total_dials = _phase_dial_count(visit=visit, phase=CallPhase.POST_MEETING)
                if total_dials >= MAX_CALL_ATTEMPTS_PER_PHASE:
                    logger.info(
                        "Visit %s post-call cap reached (%d/%d dials) — no new attempt.",
                        visit.id,
                        total_dials,
                        MAX_CALL_ATTEMPTS_PER_PHASE,
                    )
                    continue

                settings = GlobalSettings.load()
                # Auto-assemble post-call prompt via the assembler service.
                # `transcript=""` is intentional here — at scheduled-dial time
                # the meeting may have just ended and no transcript exists yet.
                # The end-of-meeting webhook will re-assemble with a fresh
                # transcript once one becomes available (see Task 27).
                run = assemble_post_call(
                    visit,
                    transcript="",
                    triggered_by=GenerationRun.TriggeredBy.SCHEDULED,
                )
                if not run.success:
                    logger.error(
                        "Failed to generate post-call prompt for visit %s: %s",
                        visit.id,
                        run.error,
                    )
                    continue
                visit.refresh_from_db()
                prompt = visit.post_call_prompt
                if not prompt:
                    logger.error(
                        "Post-call prompt empty after assembly for visit %s "
                        "(likely both fields locked)",
                        visit.id,
                    )
                    continue

                call = CallAttempt.objects.create(
                    visit=visit,
                    phase=CallPhase.POST_MEETING,
                    scheduled_offset_minutes=settings.post_call_offset_minutes,
                    status=CallStatus.SCHEDULED,
                    scheduled_time=timezone.now(),
                )

                # PR 6: pass `visit.post_call_first_message` — was hardcoded None.
                result = trigger_agent_call(
                    agent_phone=visit.agent.phone_number,
                    prompt_text=prompt,
                    context_data={"visit_id": visit.id, "client": visit.client.name},
                    call_attempt=call,
                    first_message_text=visit.post_call_first_message or None,
                )

                if result.get("success"):
                    visit.status = VisitStatus.POST_CALL_DONE
                    visit.save(update_fields=["status", "updated_at"])
                    triggered += 1
                else:
                    logger.error(
                        f"Post-call trigger failed for visit {visit.id}: {result.get('error')}"
                    )

            except Exception as e:
                logger.error(f"Error processing post-call for visit {visit.id}: {e}", exc_info=True)

        if triggered:
            logger.info(f"Visit post-calls: {triggered} triggered")
        return {"triggered": triggered}

    except Exception as e:
        logger.error(f"Error in process_visit_post_calls: {e}", exc_info=True)
        raise


def process_visit_post_call_completion(call_attempt_id: int):
    """
    Called after a post-call completes (from webhook).
    Summarizes transcript and pushes to CRM.

    Args:
        call_attempt_id: ID of the completed CallAttempt.
    """
    from voice.crm import get_crm_provider

    from .constants import VisitStatus
    from .models import CallAttempt
    from .services.llm import summarize_call_transcript

    try:
        call = CallAttempt.objects.select_related("visit", "visit__client").get(id=call_attempt_id)
        visit = call.visit
        if not visit:
            return

        # Summarize the transcript
        if call.transcript:
            context = f"Client: {visit.client.name}\nMeeting: {visit.title}"
            summary = summarize_call_transcript(call.transcript, context)
            if summary:
                visit.post_call_summary = summary
                call.summary = summary
                call.save(update_fields=["summary", "updated_at"])

        # Push to CRM
        if visit.crm_deal_id and (visit.post_call_summary or call.transcript):
            crm = get_crm_provider()
            if crm.is_configured():
                note_text = visit.post_call_summary or call.transcript
                subject = f"Post-Meeting Debrief: {visit.title} ({visit.client.name})"
                result = crm.post_note_to_deal(visit.crm_deal_id, note_text, subject)
                if result.get("success"):
                    visit.crm_synced = True
                    log_activity(
                        user=visit.agent,
                        action=f"Post-call summary synced to CRM deal {visit.crm_deal_id}",
                        details={"visit_id": visit.id, "note_id": result.get("note_id")},
                    )
                else:
                    log_activity(
                        user=visit.agent,
                        action=f"CRM sync failed for visit {visit.id}",
                        details={"error": result.get("error")},
                        level=LogLevel.ERROR,
                    )

        visit.status = VisitStatus.COMPLETE
        visit.save(update_fields=["post_call_summary", "crm_synced", "status", "updated_at"])

        # Closed-loop: distill new lessons into the client's memory after
        # every successful post-call summary. Failures are logged but never
        # propagated — the post-call summary itself is the user-visible
        # success and must not be invalidated by a downstream LLM hiccup.
        try:
            from .services.lessons import distill_lessons

            # Best-effort outcome from the analyze_post_call structured analysis;
            # the prior `getattr(call, "outcome", "")` always returned "" because
            # CallAttempt has no `outcome` field (Code Review F3).
            outcome = ""
            if isinstance(getattr(call, "analysis", None), dict):
                for k in ("objective_attained", "outcome", "status_label"):
                    v = call.analysis.get(k)
                    if isinstance(v, str) and v:
                        outcome = v
                        break

            distill_lessons(
                client=visit.client,
                new_post_call_summary=visit.post_call_summary or "",
                evaluation_outcome=outcome,
            )
        except Exception:
            logger.exception(
                "distill_lessons failed for visit=%s — debrief still complete",
                visit.id,
            )

    except CallAttempt.DoesNotExist:
        logger.error(f"CallAttempt {call_attempt_id} not found for post-call completion")
    except Exception as e:
        logger.error(f"Error in process_visit_post_call_completion: {e}", exc_info=True)
