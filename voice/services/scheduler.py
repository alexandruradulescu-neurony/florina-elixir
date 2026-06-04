"""
Call Scheduling Service.

Handles call pre-programming and scheduling logic including:
- Pre-programming calls for meetings
- Determining when calls should be triggered
- Managing call retry logic
"""

import logging
from datetime import timedelta
from typing import Any

from django.utils import timezone

from voice.constants import (
    POST_MEETING_OFFSETS,
    PRE_MEETING_OFFSETS,
    CallPhase,
    CallStatus,
    LogLevel,
)
from voice.models import CallAttempt, Meeting
from voice.selectors import get_meetings_for_post_call_check, get_meetings_for_pre_call_check

from .logging import log_activity

logger = logging.getLogger(__name__)


# ============================================================================
# Call Pre-Programming Logic (Hybrid Approach)
# ============================================================================


def pre_program_meeting_calls(meeting: Meeting, force_recreate: bool = False) -> dict[str, Any]:
    """
    Pre-program CallAttempts for a meeting.

    Pre-meeting: Only creates the -60 minute call initially.
    - If -60 fails, a -30 call will be created automatically
    - If -30 fails, it will retry every 5 minutes until meeting starts

    Post-meeting: Creates all post-meeting calls (+15, +30).
    - Failed calls will retry every 5 minutes after meeting ends

    This creates CallAttempt records upfront when a meeting is created/updated,
    providing better visibility and resilience.

    Args:
        meeting: Meeting instance
        force_recreate: If True, delete existing scheduled calls and recreate

    Returns:
        Dictionary with results: {'created': count, 'updated': count, 'deleted': count}
    """
    results = {"created": 0, "updated": 0, "deleted": 0}

    # Calculate scheduled times for all calls
    # For pre-meeting: only create the -60 minute call initially
    # The -30 minute call will be created as a retry if -60 fails
    # For post-meeting: create all calls (they'll retry if needed)
    all_offsets = []
    # Only create the first pre-meeting call (-60 minutes)
    scheduled_time = meeting.start_time + timedelta(minutes=PRE_MEETING_OFFSETS[0])
    all_offsets.append(("PRE", PRE_MEETING_OFFSETS[0], scheduled_time))

    # Create all post-meeting calls
    for offset in POST_MEETING_OFFSETS:
        scheduled_time = meeting.end_time + timedelta(minutes=offset)
        all_offsets.append(("POST", offset, scheduled_time))

    # If force_recreate, delete existing scheduled calls
    if force_recreate:
        deleted = CallAttempt.objects.filter(meeting=meeting, status=CallStatus.SCHEDULED).delete()
        results["deleted"] = deleted[0]

    # Create or update CallAttempts for each offset
    for phase, offset, scheduled_time in all_offsets:
        now = timezone.now()

        # For pre-meeting calls: if meeting is created late, still create the call
        # if it's less than 1 hour before meeting (or if -30 call and less than 30 min before)
        if phase == "PRE":
            # For -60 call: create if meeting hasn't started yet (even if call time passed)
            # For -30 call: create if meeting hasn't started yet (even if call time passed)
            if meeting.start_time <= now:
                # Meeting has already started, skip pre-meeting calls
                continue
            # Meeting hasn't started, create the call attempt (scheduler will handle timing)
        else:
            # For post-meeting calls: skip if call time is in the past
            if scheduled_time < now:
                continue

        # Check if a CallAttempt already exists for this offset
        existing = CallAttempt.objects.filter(
            meeting=meeting, phase=phase, scheduled_offset_minutes=offset
        ).first()

        if existing:
            # Update existing if it's still scheduled and time changed
            if (
                existing.status == CallStatus.SCHEDULED
                and existing.scheduled_time != scheduled_time
            ):
                existing.scheduled_time = scheduled_time
                existing.save()
                results["updated"] += 1
        else:
            # Create new CallAttempt
            CallAttempt.objects.create(
                meeting=meeting,
                phase=phase,
                scheduled_offset_minutes=offset,
                scheduled_time=scheduled_time,
                status=CallStatus.SCHEDULED,
            )
            results["created"] += 1

    log_activity(
        meeting=meeting, user=meeting.agent, action="Meeting calls pre-programmed", details=results
    )

    return results


def cleanup_cancelled_meeting_calls(meeting: Meeting) -> int:
    """
    Cancel all scheduled CallAttempts for a meeting that was deleted/cancelled.

    Args:
        meeting: Meeting instance (may be deleted, so use meeting_id if needed)

    Returns:
        Number of calls cancelled
    """
    cancelled = CallAttempt.objects.filter(meeting=meeting, status=CallStatus.SCHEDULED).update(
        status=CallStatus.FAILED
    )

    if cancelled > 0:
        log_activity(
            meeting=meeting,
            action=f"Cancelled {cancelled} scheduled calls for deleted meeting",
            level=LogLevel.WARNING,
        )

    return cancelled


# ============================================================================
# Scheduler Decision Logic
# ============================================================================


def should_trigger_pre_call(meeting: Meeting, offset: int) -> bool:
    """
    Determine if a pre-meeting call should be triggered for a given offset.

    Args:
        meeting: Meeting instance
        offset: Offset in minutes (negative, e.g., -60, -30)

    Returns:
        True if call should be triggered, False otherwise
    """
    # If pre-call is already completed, don't trigger
    if meeting.is_pre_call_completed:
        return False

    # Check if call attempt already exists for this offset
    existing_attempt = CallAttempt.objects.filter(
        meeting=meeting, phase=CallPhase.PRE_MEETING, scheduled_offset_minutes=offset
    ).first()

    if existing_attempt:
        # If attempt exists and is completed, don't trigger again
        if existing_attempt.status == CallStatus.COMPLETED:
            return False
        # If attempt exists but failed/no answer, allow retry if it's the retry offset
        return offset == PRE_MEETING_OFFSETS[1] and existing_attempt.status in [
            CallStatus.NO_ANSWER,
            CallStatus.FAILED,
        ]

    # For first call (-60 mins), always trigger if no attempt exists
    if offset == PRE_MEETING_OFFSETS[0]:
        return True

    # For retry call (-30 mins), only trigger if first call wasn't completed
    if offset == PRE_MEETING_OFFSETS[1]:
        first_call_attempt = CallAttempt.objects.filter(
            meeting=meeting,
            phase=CallPhase.PRE_MEETING,
            scheduled_offset_minutes=PRE_MEETING_OFFSETS[0],
        ).first()

        return not (first_call_attempt and first_call_attempt.status == CallStatus.COMPLETED)

    return False


def should_trigger_post_call(meeting: Meeting, offset: int) -> bool:
    """
    Determine if a post-meeting call should be triggered for a given offset.

    Args:
        meeting: Meeting instance
        offset: Offset in minutes (positive, e.g., 15, 30)

    Returns:
        True if call should be triggered, False otherwise
    """
    # If post-call is already completed, don't trigger
    if meeting.is_post_call_completed:
        return False

    # Check if call attempt already exists for this offset
    existing_attempt = CallAttempt.objects.filter(
        meeting=meeting, phase=CallPhase.POST_MEETING, scheduled_offset_minutes=offset
    ).first()

    if existing_attempt:
        # If attempt exists and is completed, don't trigger again
        if existing_attempt.status == CallStatus.COMPLETED:
            return False
        # If attempt exists but failed/no answer, allow retry if it's the retry offset
        return offset == POST_MEETING_OFFSETS[1] and existing_attempt.status in [
            CallStatus.NO_ANSWER,
            CallStatus.FAILED,
        ]

    # For first call (+15 mins), always trigger if no attempt exists
    if offset == POST_MEETING_OFFSETS[0]:
        return True

    # For retry call (+30 mins), only trigger if first call wasn't completed
    if offset == POST_MEETING_OFFSETS[1]:
        first_call_attempt = CallAttempt.objects.filter(
            meeting=meeting,
            phase=CallPhase.POST_MEETING,
            scheduled_offset_minutes=POST_MEETING_OFFSETS[0],
        ).first()

        return not (first_call_attempt and first_call_attempt.status == CallStatus.COMPLETED)

    return False


def check_pre_meeting_calls() -> list[tuple[Meeting, int]]:
    """Find meetings that need pre-meeting calls triggered.

    NOTE: This is part of the legacy meeting-flow. Its scheduled caller
    (`check_and_trigger_calls`) was dropped, but two surviving consumers
    still rely on it and will be migrated in a follow-up PR (Y1b):
      * `ProgrammedCallsView` for the manager dashboard's "programmed
        calls" page.
      * `check_scheduler` diagnostic management command.

    Returns:
        List of tuples (Meeting, offset_minutes) for meetings that need calls
    """
    meetings_to_call = []
    meetings_with_offsets = get_meetings_for_pre_call_check()

    for meeting, offset in meetings_with_offsets:
        if should_trigger_pre_call(meeting, offset):
            meetings_to_call.append((meeting, offset))
            log_activity(
                meeting=meeting,
                action=f"Pre-meeting call scheduled for offset {offset} minutes",
                details={"offset_minutes": offset, "meeting_start": meeting.start_time.isoformat()},
            )

    return meetings_to_call


def check_post_meeting_calls() -> list[tuple[Meeting, int]]:
    """Find meetings that need post-meeting calls triggered. Same legacy
    notes as `check_pre_meeting_calls` — kept until Y1b migrates the two
    surviving consumers.

    Returns:
        List of tuples (Meeting, offset_minutes) for meetings that need calls
    """
    meetings_to_call = []
    meetings_with_offsets = get_meetings_for_post_call_check()

    for meeting, offset in meetings_with_offsets:
        if should_trigger_post_call(meeting, offset):
            meetings_to_call.append((meeting, offset))
            log_activity(
                meeting=meeting,
                action=f"Post-meeting call scheduled for offset {offset} minutes",
                details={"offset_minutes": offset, "meeting_end": meeting.end_time.isoformat()},
            )

    return meetings_to_call
