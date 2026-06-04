"""
Scheduled tasks for the voice app using APScheduler.
These functions are registered with APScheduler in voice/apps.py.
"""

import logging
from datetime import timedelta
from threading import Thread

from django.utils import timezone

from .constants import CallPhase, CallStatus, LogLevel
from .models import CallAttempt, Meeting, User
from .selectors import get_active_prompt, get_sales_agents
from .services import (
    check_post_meeting_calls,
    check_pre_meeting_calls,
    format_first_message_with_context,
    format_prompt_with_context,
    log_activity,
    sync_call_status_from_api,
    trigger_agent_call,
)

logger = logging.getLogger(__name__)


def _resolve_prompt_for_call(call_attempt):
    """Return ``(prompt_text, first_message_text)`` for an outbound dial.

    PR 6 — fixes prod bug where automatic dials bypassed the Auto Prompt
    Assembler's output and rang the agent with EL's default greeting.

    Resolution order:
      1. If the CallAttempt is linked to a Visit (new pipeline) AND that
         Visit has the appropriate `pre_call_prompt` / `post_call_prompt`
         populated by the assembler → use it directly (and its sibling
         `*_first_message`). This is the correct path for every
         visit-pipeline dial.
      2. Otherwise (or if the visit's prompt field is empty), fall back
         to the legacy `VoicePrompt` model via `get_active_prompt(phase)`.
         The legacy `VoicePrompt` table is deprecated and typically empty
         on prod, so this fallback usually means "no prompt available".

    Returns `(None, None)` when no usable prompt source exists — the
    caller must mark the CallAttempt as FAILED rather than dialing
    without an override (which would let EL fall back to its default
    agent greeting, the original bug symptom).
    """
    visit = getattr(call_attempt, "visit", None)
    if visit is not None:
        if call_attempt.phase == CallPhase.PRE_MEETING:
            body = (visit.pre_call_prompt or "").strip()
            first = (visit.pre_call_first_message or "").strip()
        else:
            body = (visit.post_call_prompt or "").strip()
            first = (visit.post_call_first_message or "").strip()
        if body:
            return body, (first or None)
        logger.warning(
            "CallAttempt %s links to visit %s but the assembled %s prompt is empty; "
            "falling back to legacy VoicePrompt.",
            call_attempt.id,
            visit.id,
            "pre-call" if call_attempt.phase == CallPhase.PRE_MEETING else "post-call",
        )

    # Legacy meeting-only fallback
    prompt = get_active_prompt(call_attempt.phase)
    if not prompt or not prompt.system_prompt or not prompt.system_prompt.strip():
        return None, None
    meeting = getattr(call_attempt, "meeting", None)
    if meeting:
        formatted = format_prompt_with_context(prompt.system_prompt, meeting)
        first_msg = (
            format_first_message_with_context(prompt.first_message, meeting)
            if prompt.first_message
            else None
        )
    else:
        formatted = prompt.system_prompt
        first_msg = prompt.first_message or None
    return formatted, first_msg


def check_and_trigger_calls():
    """
    Main periodic task that checks for meetings needing calls and triggers them.
    Uses hybrid approach:
    1. Primary: Check for pre-programmed CallAttempts ready to execute
    2. Backup: Window-based check for any missed calls

    Runs every 5 minutes via APScheduler.
    """
    from django.utils import timezone

    from .constants import CallStatus
    from .models import CallAttempt

    logger.info("Starting call check task")

    try:
        now = timezone.now()
        triggered_count = 0

        # PRIMARY: Check for pre-programmed CallAttempts ready to execute
        # Look for scheduled calls where scheduled_time <= now
        ready_calls = CallAttempt.objects.filter(
            status=CallStatus.SCHEDULED, scheduled_time__lte=now
        ).select_related("meeting", "meeting__agent")

        logger.info(f"Found {ready_calls.count()} pre-programmed calls ready to execute")

        for call_attempt in ready_calls:
            # Validate timing constraints
            if call_attempt.phase == "PRE":
                # Pre-meeting: execute if meeting hasn't started or just started (within 5 minutes)
                # This handles cases where meeting was created late
                time_since_meeting_start = now - call_attempt.meeting.start_time
                # Meeting hasn't started yet OR meeting just started (within 5 minutes grace period)
                can_execute = (call_attempt.meeting.start_time > now) or (
                    call_attempt.meeting.start_time <= now
                    and 0 <= time_since_meeting_start.total_seconds() <= 300
                )

                logger.info(
                    f"Pre-meeting call {call_attempt.id} for meeting '{call_attempt.meeting.title}': "
                    f"meeting_start={call_attempt.meeting.start_time}, now={now}, "
                    f"can_execute={can_execute}"
                )

                if can_execute:
                    # Execute the call using existing CallAttempt
                    logger.info(f"Triggering pre-meeting call {call_attempt.id}")
                    thread = Thread(target=execute_scheduled_call, args=(call_attempt.id,))
                    thread.daemon = True
                    thread.start()
                    triggered_count += 1
            else:  # POST
                # Post-meeting: only execute if meeting has ended
                can_execute = call_attempt.meeting.end_time < now

                logger.info(
                    f"Post-meeting call {call_attempt.id} for meeting '{call_attempt.meeting.title}': "
                    f"meeting_end={call_attempt.meeting.end_time}, now={now}, "
                    f"can_execute={can_execute}"
                )

                if can_execute:
                    # Execute the call using existing CallAttempt
                    logger.info(f"Triggering post-meeting call {call_attempt.id}")
                    thread = Thread(target=execute_scheduled_call, args=(call_attempt.id,))
                    thread.daemon = True
                    thread.start()
                    triggered_count += 1

        # RETRY LOGIC: Check for failed calls that need retries
        # Pre-meeting: retry failed calls every 5 minutes until meeting starts
        from .constants import MAX_CALL_ATTEMPTS_PER_PHASE

        def _attempts_for_call(ca):
            """Count CallAttempts for the same (visit OR meeting, phase) combo.

            The hard cap applies to TOTAL calls (initial + retries) per
            visit/meeting+phase — not just retries. Once `MAX_CALL_ATTEMPTS_PER_PHASE`
            rows exist, no more dials of any kind.
            """
            qs = CallAttempt.objects.filter(phase=ca.phase)
            if ca.visit_id:
                qs = qs.filter(visit_id=ca.visit_id)
            elif ca.meeting_id:
                qs = qs.filter(meeting_id=ca.meeting_id)
            else:
                return 1  # standalone — treat as exhausted-after-self
            return qs.count()

        failed_pre_calls = CallAttempt.objects.filter(
            meeting__start_time__gt=now,  # Meeting hasn't started
            phase="PRE",
            status__in=[CallStatus.NO_ANSWER, CallStatus.FAILED],
            meeting__agent__is_sales_agent=True,
        ).select_related("meeting", "meeting__agent")

        for call_attempt in failed_pre_calls:
            # PR 6 hard cap: stop dialing once we've hit MAX_CALL_ATTEMPTS_PER_PHASE
            # for this (visit OR meeting, phase) combo. Prevents the 50-calls-per-
            # night runaway flagged in prod.
            attempts = _attempts_for_call(call_attempt)
            if attempts >= MAX_CALL_ATTEMPTS_PER_PHASE:
                logger.info(
                    "Pre-call retry suppressed: CallAttempt #%s — already %d/%d attempts for this phase.",
                    call_attempt.id,
                    attempts,
                    MAX_CALL_ATTEMPTS_PER_PHASE,
                )
                continue

            # Check if it's been at least 5 minutes since last attempt
            # Use updated_at as proxy for last retry time
            time_since_last_attempt = now - call_attempt.updated_at
            if (
                time_since_last_attempt.total_seconds() >= 300
                and not call_attempt.meeting.is_pre_call_completed
            ):  # 5 minutes
                # Retry the call
                thread = Thread(target=retry_failed_call, args=(call_attempt.id,))
                thread.daemon = True
                thread.start()
                triggered_count += 1

        # Post-meeting: retry failed calls every 5 minutes after meeting ends
        failed_post_calls = CallAttempt.objects.filter(
            meeting__end_time__lt=now,  # Meeting has ended
            phase="POST",
            status__in=[CallStatus.NO_ANSWER, CallStatus.FAILED],
            meeting__agent__is_sales_agent=True,
        ).select_related("meeting", "meeting__agent")

        for call_attempt in failed_post_calls:
            attempts = _attempts_for_call(call_attempt)
            if attempts >= MAX_CALL_ATTEMPTS_PER_PHASE:
                logger.info(
                    "Post-call retry suppressed: CallAttempt #%s — already %d/%d attempts for this phase.",
                    call_attempt.id,
                    attempts,
                    MAX_CALL_ATTEMPTS_PER_PHASE,
                )
                continue

            # Check if it's been at least 5 minutes since last attempt
            time_since_last_attempt = now - call_attempt.updated_at
            if (
                time_since_last_attempt.total_seconds() >= 300
                and not call_attempt.meeting.is_post_call_completed
            ):  # 5 minutes
                # Retry the call
                thread = Thread(target=retry_failed_call, args=(call_attempt.id,))
                thread.daemon = True
                thread.start()
                triggered_count += 1

        # BACKUP: Window-based check for any missed calls
        # This catches calls that might not have been pre-programmed
        pre_meeting_calls = check_pre_meeting_calls()
        for meeting, offset in pre_meeting_calls:
            # Check if CallAttempt already exists
            existing = CallAttempt.objects.filter(
                meeting=meeting,
                phase="PRE",
                scheduled_offset_minutes=offset,
                status=CallStatus.SCHEDULED,
            ).exists()

            if not existing:
                # Only trigger if no scheduled CallAttempt exists
                thread = Thread(target=trigger_pre_meeting_call, args=(meeting.id, offset))
                thread.daemon = True
                thread.start()
                triggered_count += 1

        post_meeting_calls = check_post_meeting_calls()
        for meeting, offset in post_meeting_calls:
            # Check if CallAttempt already exists
            existing = CallAttempt.objects.filter(
                meeting=meeting,
                phase="POST",
                scheduled_offset_minutes=offset,
                status=CallStatus.SCHEDULED,
            ).exists()

            if not existing:
                # Only trigger if no scheduled CallAttempt exists
                thread = Thread(target=trigger_post_meeting_call, args=(meeting.id, offset))
                thread.daemon = True
                thread.start()
                triggered_count += 1

        logger.info(
            f"Call check completed: {triggered_count} calls triggered ({len(ready_calls)} from pre-programmed, {len(pre_meeting_calls)} pre + {len(post_meeting_calls)} post from backup)"
        )

        return {
            "triggered": triggered_count,
            "pre_programmed": len(ready_calls),
            "backup_pre": len(pre_meeting_calls),
            "backup_post": len(post_meeting_calls),
        }

    except Exception as e:
        logger.error(f"Error in check_and_trigger_calls: {e}", exc_info=True)
        log_activity(
            action="Call check task failed", details={"error": str(e)}, level=LogLevel.ERROR
        )
        raise


def execute_scheduled_call(call_attempt_id: int):
    """
    Execute a pre-programmed CallAttempt that's ready to run.
    Uses the existing CallAttempt record instead of creating a new one.
    """
    from .models import CallAttempt

    try:
        call_attempt = CallAttempt.objects.get(id=call_attempt_id)
        # Visit-linked attempts use the new pipeline; meeting-only attempts
        # use the legacy path. Pull agent from whichever is available.
        visit = call_attempt.visit
        meeting = call_attempt.meeting
        agent = (visit.agent if visit else None) or (meeting.agent if meeting else None)
        if agent is None:
            logger.error(
                "CallAttempt %s has neither visit nor meeting — cannot resolve agent.",
                call_attempt_id,
            )
            call_attempt.status = CallStatus.FAILED
            call_attempt.save()
            return {"success": False, "error": "No agent resolvable"}

        # Validate agent has phone number
        if not agent.phone_number:
            logger.warning(f"Agent {agent.username} has no phone number for call {call_attempt_id}")
            call_attempt.status = CallStatus.FAILED
            call_attempt.save()
            return {"success": False, "error": "No phone number"}

        # PR 6: resolve prompt via shared helper — prefers visit.pre/post_call_prompt
        # when a Visit is linked (the new pipeline). The prior code unconditionally
        # called `get_active_prompt(phase)` and ignored the assembled prompt.
        formatted_prompt, formatted_first_message = _resolve_prompt_for_call(call_attempt)
        if not formatted_prompt:
            logger.error(
                "No usable prompt for CallAttempt %s (phase=%s). Marking FAILED.",
                call_attempt_id,
                call_attempt.phase,
            )
            call_attempt.status = CallStatus.FAILED
            call_attempt.save()
            return {"success": False, "error": "No usable prompt source"}

        # Prepare context data
        context_data = {
            "meeting_id": getattr(meeting, "id", None),
            "visit_id": getattr(visit, "id", None),
            "offset_minutes": call_attempt.scheduled_offset_minutes,
            "call_attempt_id": call_attempt.id,
        }

        # Trigger the call using existing CallAttempt
        result = trigger_agent_call(
            agent_phone=agent.phone_number,
            prompt_text=formatted_prompt,
            context_data=context_data,
            call_attempt=call_attempt,
            first_message_text=formatted_first_message,
        )

        if result["success"]:
            logger.info(f"Scheduled call {call_attempt_id} executed successfully")
        else:
            logger.error(
                f"Failed to execute scheduled call {call_attempt_id}: {result.get('error')}"
            )

        return result

    except CallAttempt.DoesNotExist:
        logger.error(f"CallAttempt {call_attempt_id} not found")
        return {"success": False, "error": "CallAttempt not found"}
    except Exception as e:
        logger.error(f"Error executing scheduled call {call_attempt_id}: {e}", exc_info=True)
        log_activity(
            action="Scheduled call execution failed",
            details={"call_attempt_id": call_attempt_id, "error": str(e)},
            level=LogLevel.ERROR,
        )
        raise


def retry_failed_call(call_attempt_id: int):
    """
    Retry a failed call attempt (NO_ANSWER or FAILED).
    Updates the existing CallAttempt and triggers a new call.
    """
    from .constants import CallStatus
    from .models import CallAttempt

    try:
        call_attempt = CallAttempt.objects.get(id=call_attempt_id)
        # Resolve agent from visit-or-meeting (PR 6).
        visit = call_attempt.visit
        meeting = call_attempt.meeting
        agent = (visit.agent if visit else None) or (meeting.agent if meeting else None)
        if agent is None:
            logger.error("CallAttempt %s (retry) has neither visit nor meeting.", call_attempt_id)
            return {"success": False, "error": "No agent resolvable"}

        # Validate agent has phone number
        if not agent.phone_number:
            logger.warning(
                f"Agent {agent.username} has no phone number for retry {call_attempt_id}"
            )
            return {"success": False, "error": "No phone number"}

        # PR 6: prefer visit.pre/post_call_prompt via shared helper.
        formatted_prompt, formatted_first_message = _resolve_prompt_for_call(call_attempt)
        if not formatted_prompt:
            logger.error(
                "No usable prompt for retry CallAttempt %s (phase=%s).",
                call_attempt_id,
                call_attempt.phase,
            )
            return {"success": False, "error": "No usable prompt source"}

        # Reset call attempt status to SCHEDULED for retry
        call_attempt.status = CallStatus.SCHEDULED
        call_attempt.external_call_id = None  # Clear old call ID
        call_attempt.save()

        # Prepare context data
        context_data = {
            "meeting_id": getattr(meeting, "id", None),
            "visit_id": getattr(visit, "id", None),
            "offset_minutes": call_attempt.scheduled_offset_minutes,
            "call_attempt_id": call_attempt.id,
            "is_retry": True,
        }

        # Trigger the call using existing CallAttempt
        result = trigger_agent_call(
            agent_phone=agent.phone_number,
            prompt_text=formatted_prompt,
            context_data=context_data,
            call_attempt=call_attempt,
            first_message_text=formatted_first_message,
        )

        if result["success"]:
            logger.info(f"Retry call {call_attempt_id} executed successfully")
            log_activity(
                meeting=meeting,
                user=agent,
                action=f"Retry call triggered for {call_attempt.get_phase_display()}",
                details={
                    "call_attempt_id": call_attempt_id,
                    "offset": call_attempt.scheduled_offset_minutes,
                },
            )
        else:
            logger.error(f"Failed to retry call {call_attempt_id}: {result.get('error')}")

        return result

    except CallAttempt.DoesNotExist:
        logger.error(f"CallAttempt {call_attempt_id} not found for retry")
        return {"success": False, "error": "CallAttempt not found"}
    except Exception as e:
        logger.error(f"Error retrying call {call_attempt_id}: {e}", exc_info=True)
        log_activity(
            action="Call retry failed",
            details={"call_attempt_id": call_attempt_id, "error": str(e)},
            level=LogLevel.ERROR,
        )
        raise


def trigger_pre_meeting_call(meeting_id: int, offset_minutes: int):
    """
    Trigger a pre-meeting call for a specific meeting and offset.

    Args:
        meeting_id: Meeting ID
        offset_minutes: Offset in minutes (negative, e.g., -60, -30)
    """
    try:
        from .constants import MAX_CALL_ATTEMPTS_PER_PHASE
        from .models import Visit

        meeting = Meeting.objects.get(id=meeting_id)
        agent = meeting.agent

        # Validate agent has phone number
        if not agent.phone_number:
            logger.warning(f"Agent {agent.username} has no phone number for meeting {meeting_id}")
            log_activity(
                meeting=meeting,
                user=agent,
                action="Pre-meeting call skipped - no phone number",
                level=LogLevel.WARNING,
            )
            return {"success": False, "error": "No phone number"}

        # PR 6: try to find a Visit linked to this Meeting so we can use the
        # assembler's prompt. Two side-by-side data models exist (Meeting and
        # Visit); the calendar sync may have produced both for the same
        # external event. We link by calendar event id when possible.
        linked_visit = None
        if meeting.external_id:
            linked_visit = Visit.objects.filter(calendar_event_id=meeting.external_id).first()

        # PR 6 hard cap: count existing CallAttempts and refuse to create more.
        existing_for_phase = CallAttempt.objects.filter(
            meeting=meeting, phase=CallPhase.PRE_MEETING
        ).count()

        # Check if CallAttempt already exists (from pre-programming)
        call_attempt = CallAttempt.objects.filter(
            meeting=meeting,
            phase=CallPhase.PRE_MEETING,
            scheduled_offset_minutes=offset_minutes,
            status=CallStatus.SCHEDULED,
        ).first()

        if not call_attempt:
            if existing_for_phase >= MAX_CALL_ATTEMPTS_PER_PHASE:
                logger.info(
                    "Meeting %s pre-call cap reached (%d/%d) — no new attempt.",
                    meeting_id,
                    existing_for_phase,
                    MAX_CALL_ATTEMPTS_PER_PHASE,
                )
                return {"success": False, "error": "Call attempt cap reached"}

            # Create new call attempt record if it doesn't exist
            scheduled_time = meeting.start_time + timedelta(minutes=offset_minutes)
            call_attempt = CallAttempt.objects.create(
                meeting=meeting,
                visit=linked_visit,  # PR 6: link to Visit if found
                phase=CallPhase.PRE_MEETING,
                scheduled_offset_minutes=offset_minutes,
                scheduled_time=scheduled_time,
                status=CallStatus.SCHEDULED,
            )
        elif linked_visit and call_attempt.visit_id is None:
            # Pre-programmed CallAttempt exists but isn't yet linked to the visit.
            # Linking it lets `_resolve_prompt_for_call` see the assembled prompt.
            call_attempt.visit = linked_visit
            call_attempt.save(update_fields=["visit", "updated_at"])

        # PR 6: resolve prompt via shared helper — prefers visit.pre_call_prompt
        # if a Visit is linked, falls through to legacy VoicePrompt otherwise.
        formatted_prompt, formatted_first_message = _resolve_prompt_for_call(call_attempt)
        if not formatted_prompt:
            logger.error("No usable prompt for pre-meeting call (meeting=%s)", meeting_id)
            log_activity(
                meeting=meeting,
                user=agent,
                action="Pre-meeting call failed - no usable prompt source",
                level=LogLevel.ERROR,
            )
            call_attempt.status = CallStatus.FAILED
            call_attempt.save()
            return {"success": False, "error": "No usable prompt source"}

        # Prepare context data
        context_data = {
            "meeting_id": meeting.id,
            "visit_id": getattr(call_attempt.visit, "id", None),
            "offset_minutes": offset_minutes,
            "call_attempt_id": call_attempt.id,
        }

        # Trigger the call
        result = trigger_agent_call(
            agent_phone=agent.phone_number,
            prompt_text=formatted_prompt,
            context_data=context_data,
            call_attempt=call_attempt,
            first_message_text=formatted_first_message,
        )

        if result["success"]:
            logger.info(
                f"Pre-meeting call triggered for meeting {meeting_id} at offset {offset_minutes}"
            )
        else:
            logger.error(f"Failed to trigger pre-meeting call: {result.get('error')}")

        return result

    except Meeting.DoesNotExist:
        logger.error(f"Meeting {meeting_id} not found")
        return {"success": False, "error": "Meeting not found"}
    except Exception as e:
        logger.error(f"Error triggering pre-meeting call: {e}", exc_info=True)
        log_activity(
            action="Pre-meeting call trigger failed",
            details={"meeting_id": meeting_id, "error": str(e)},
            level=LogLevel.ERROR,
        )
        raise


def trigger_post_meeting_call(meeting_id: int, offset_minutes: int):
    """
    Trigger a post-meeting call for a specific meeting and offset.

    Args:
        meeting_id: Meeting ID
        offset_minutes: Offset in minutes (positive, e.g., 15, 30)
    """
    try:
        from .constants import MAX_CALL_ATTEMPTS_PER_PHASE
        from .models import Visit

        meeting = Meeting.objects.get(id=meeting_id)
        agent = meeting.agent

        # Validate agent has phone number
        if not agent.phone_number:
            logger.warning(f"Agent {agent.username} has no phone number for meeting {meeting_id}")
            log_activity(
                meeting=meeting,
                user=agent,
                action="Post-meeting call skipped - no phone number",
                level=LogLevel.WARNING,
            )
            return {"success": False, "error": "No phone number"}

        # PR 6: link to Visit if one exists for this calendar event.
        linked_visit = None
        if meeting.external_id:
            linked_visit = Visit.objects.filter(calendar_event_id=meeting.external_id).first()

        # PR 6 hard cap.
        existing_for_phase = CallAttempt.objects.filter(
            meeting=meeting, phase=CallPhase.POST_MEETING
        ).count()

        # Check if CallAttempt already exists (from pre-programming)
        call_attempt = CallAttempt.objects.filter(
            meeting=meeting,
            phase=CallPhase.POST_MEETING,
            scheduled_offset_minutes=offset_minutes,
            status=CallStatus.SCHEDULED,
        ).first()

        if not call_attempt:
            if existing_for_phase >= MAX_CALL_ATTEMPTS_PER_PHASE:
                logger.info(
                    "Meeting %s post-call cap reached (%d/%d) — no new attempt.",
                    meeting_id,
                    existing_for_phase,
                    MAX_CALL_ATTEMPTS_PER_PHASE,
                )
                return {"success": False, "error": "Call attempt cap reached"}

            # Create new call attempt record if it doesn't exist
            scheduled_time = meeting.end_time + timedelta(minutes=offset_minutes)
            call_attempt = CallAttempt.objects.create(
                meeting=meeting,
                visit=linked_visit,  # PR 6
                phase=CallPhase.POST_MEETING,
                scheduled_offset_minutes=offset_minutes,
                scheduled_time=scheduled_time,
                status=CallStatus.SCHEDULED,
            )
        elif linked_visit and call_attempt.visit_id is None:
            call_attempt.visit = linked_visit
            call_attempt.save(update_fields=["visit", "updated_at"])

        # PR 6: shared prompt resolver.
        formatted_prompt, formatted_first_message = _resolve_prompt_for_call(call_attempt)
        if not formatted_prompt:
            logger.error("No usable prompt for post-meeting call (meeting=%s)", meeting_id)
            log_activity(
                meeting=meeting,
                user=agent,
                action="Post-meeting call failed - no usable prompt source",
                level=LogLevel.ERROR,
            )
            call_attempt.status = CallStatus.FAILED
            call_attempt.save()
            return {"success": False, "error": "No usable prompt source"}

        # Prepare context data
        context_data = {
            "meeting_id": meeting.id,
            "visit_id": getattr(call_attempt.visit, "id", None),
            "offset_minutes": offset_minutes,
            "call_attempt_id": call_attempt.id,
        }

        # Trigger the call
        result = trigger_agent_call(
            agent_phone=agent.phone_number,
            prompt_text=formatted_prompt,
            context_data=context_data,
            call_attempt=call_attempt,
            first_message_text=formatted_first_message,
        )

        if result["success"]:
            logger.info(
                f"Post-meeting call triggered for meeting {meeting_id} at offset {offset_minutes}"
            )
        else:
            logger.error(f"Failed to trigger post-meeting call: {result.get('error')}")

        return result

    except Meeting.DoesNotExist:
        logger.error(f"Meeting {meeting_id} not found")
        return {"success": False, "error": "Meeting not found"}
    except Exception as e:
        logger.error(f"Error triggering post-meeting call: {e}", exc_info=True)
        log_activity(
            action="Post-meeting call trigger failed",
            details={"meeting_id": meeting_id, "error": str(e)},
            level=LogLevel.ERROR,
        )
        raise


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
    from datetime import timedelta

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

                # PR 6 hard cap: also count FAILED/NO_ANSWER. The query above
                # skipped them, so without this guard a Visit whose first attempt
                # NO_ANSWER'd would keep getting fresh attempts every 5 minutes.
                total_attempts = CallAttempt.objects.filter(
                    visit=visit, phase=CallPhase.PRE_MEETING
                ).count()
                if total_attempts >= MAX_CALL_ATTEMPTS_PER_PHASE:
                    logger.info(
                        "Visit %s pre-call cap reached (%d/%d) — no new attempt.",
                        visit.id,
                        total_attempts,
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
                total_attempts = CallAttempt.objects.filter(
                    visit=visit, phase=CallPhase.POST_MEETING
                ).count()
                if total_attempts >= MAX_CALL_ATTEMPTS_PER_PHASE:
                    logger.info(
                        "Visit %s post-call cap reached (%d/%d) — no new attempt.",
                        visit.id,
                        total_attempts,
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
