"""
ElevenLabs Conversational AI Integration Service.

Handles all interactions with ElevenLabs API including:
- Voice call initiation
- Call status polling (fallback for webhooks)
- Webhook configuration management
"""

import json
import logging
from datetime import timedelta
from typing import Any

from django.utils import timezone

from voice.constants import PRE_MEETING_OFFSETS, CallPhase, CallStatus, LogLevel
from voice.models import CallAttempt
from voice.utils import format_phone_number

from .logging import log_activity
from .pipedrive import sync_note_to_pipedrive

logger = logging.getLogger(__name__)


def _ca_user(call_attempt: CallAttempt):
    """Resolve the sales-agent User for a CallAttempt regardless of source path.

    The codebase is mid-migration from the legacy `Meeting` model to the newer
    `Visit` model. `CallAttempt` carries nullable FKs to BOTH: the new
    `process_visit_pre_calls` / `process_visit_post_calls` pipelines create
    rows with `visit` set and `meeting=None`; legacy `check_and_trigger_calls`
    paths set `meeting` and leave `visit=None`.

    Every caller that historically did `call_attempt.meeting.agent` will
    AttributeError on Visit-based rows. Use this helper instead — it tries the
    Visit path first (the documented new entry point) and falls back to the
    Meeting path for legacy rows. Returns None only when the CallAttempt is
    orphaned (data integrity bug); `log_activity` accepts `user=None`.
    """
    if call_attempt.visit_id and call_attempt.visit:
        return call_attempt.visit.agent
    if call_attempt.meeting_id and call_attempt.meeting:
        return call_attempt.meeting.agent
    return None


# ============================================================================
# ElevenLabs API Polling Service (Fallback when webhooks fail)
# ============================================================================


def fetch_call_status_from_elevenlabs(call_id: str) -> dict[str, Any]:
    """
    Fetch call status, transcript, and summary from ElevenLabs API.
    This is a fallback when webhooks are not received.
    Tries multiple API endpoints to find the correct one.

    Args:
        call_id: ElevenLabs conversation_id/call_id

    Returns:
        Dictionary with call data: {'success': bool, 'status': str, 'transcript': str, 'recording_url': str, 'summary': str, 'summary_title': str, 'error': str}
    """
    import requests
    from decouple import config

    result = {
        "success": False,
        "status": None,
        "transcript": None,
        "recording_url": None,
        "summary": None,
        "summary_title": None,
        "error": None,
        "endpoint_used": None,
    }

    elevenlabs_api_key = config("ELEVENLABS_API_KEY", default="")
    if not elevenlabs_api_key:
        result["error"] = "Missing ElevenLabs API key"
        return result

    headers = {"xi-api-key": elevenlabs_api_key}

    # Try multiple possible endpoints
    # ElevenLabs API endpoints may vary - we try common patterns
    endpoints_to_try = [
        f"https://api.elevenlabs.io/v1/convai/conversations/{call_id}",
        f"https://api.elevenlabs.io/v1/convai/calls/{call_id}",
        f"https://api.elevenlabs.io/v1/conversations/{call_id}",
        f"https://api.elevenlabs.io/v1/calls/{call_id}",
    ]

    logger.info(f"Fetching call status from ElevenLabs API for call_id: {call_id}")

    for api_url in endpoints_to_try:
        try:
            response = requests.get(api_url, headers=headers, timeout=30)

            if response.status_code == 200:
                data = response.json()
                logger.info("Successfully fetched call status from ElevenLabs API")

                result["success"] = True
                result["endpoint_used"] = api_url

                # Extract status
                status = data.get("status", "").lower()
                result["status"] = status

                # Extract transcript - try multiple locations
                transcript_data = None
                transcript_locations = [
                    data.get("transcript"),
                    data.get("conversation_transcript"),
                    data.get("data", {}).get("transcript")
                    if isinstance(data.get("data"), dict)
                    else None,
                ]

                for loc in transcript_locations:
                    if loc:
                        transcript_data = loc
                        break

                if transcript_data:
                    if isinstance(transcript_data, list):
                        # ElevenLabs sends transcript as a list of turn objects
                        transcript_lines = []
                        for turn in transcript_data:
                            if isinstance(turn, dict):
                                role = turn.get("role", "unknown")
                                message = (
                                    turn.get("message") or turn.get("content") or turn.get("text")
                                )
                                if message:
                                    role_label = (
                                        "Agent"
                                        if role == "agent"
                                        else "User"
                                        if role == "user"
                                        else role.title()
                                    )
                                    transcript_lines.append(f"{role_label}: {message}")
                        result["transcript"] = (
                            "\n\n".join(transcript_lines) if transcript_lines else None
                        )
                    elif isinstance(transcript_data, dict):
                        # Extract from structured format (same as webhook handler)
                        turns = transcript_data.get("turns", [])
                        if turns:
                            transcript_lines = []
                            for turn in turns:
                                if isinstance(turn, dict):
                                    role = turn.get("role", "unknown")
                                    content = (
                                        turn.get("content", "")
                                        or turn.get("text", "")
                                        or turn.get("message", "")
                                    )
                                    if content:
                                        role_label = (
                                            "Agent"
                                            if role == "agent"
                                            else "User"
                                            if role == "user"
                                            else role.title()
                                        )
                                        transcript_lines.append(f"{role_label}: {content}")
                            result["transcript"] = (
                                "\n\n".join(transcript_lines) if transcript_lines else None
                            )
                        else:
                            # Try direct text fields
                            result["transcript"] = (
                                transcript_data.get("text")
                                or transcript_data.get("content")
                                or transcript_data.get("transcript")
                                or str(transcript_data)
                                if transcript_data
                                else None
                            )
                    elif isinstance(transcript_data, str):
                        result["transcript"] = transcript_data
                    else:
                        result["transcript"] = str(transcript_data) if transcript_data else None
                else:
                    result["transcript"] = None

                # Extract recording URL - try multiple locations
                recording_url = None
                recording_locations = [
                    data.get("recording_url"),
                    data.get("audio_url"),
                    data.get("metadata", {}).get("recording_url")
                    if isinstance(data.get("metadata"), dict)
                    else None,
                    data.get("metadata", {}).get("audio_url")
                    if isinstance(data.get("metadata"), dict)
                    else None,
                    data.get("data", {}).get("metadata", {}).get("recording_url")
                    if isinstance(data.get("data", {}).get("metadata"), dict)
                    else None,
                ]

                for loc in recording_locations:
                    if loc:
                        recording_url = loc
                        break

                result["recording_url"] = recording_url

                # Extract summary from analysis data
                analysis = data.get("analysis", {})
                if isinstance(analysis, dict):
                    result["summary"] = analysis.get("transcript_summary") or analysis.get(
                        "summary"
                    )
                    result["summary_title"] = analysis.get("call_summary_title")
                else:
                    result["summary"] = None
                    result["summary_title"] = None

                # Success - return early
                return result

            elif response.status_code == 404:
                # Continue to next endpoint
                continue
            else:
                # Try to parse error message
                try:
                    error_data = response.json()
                    error_msg = error_data.get(
                        "detail",
                        error_data.get("message", error_data.get("error", "Unknown error")),
                    )
                except ValueError:
                    error_msg = response.text[:200]

                # Continue to next endpoint unless it's a clear auth error
                if response.status_code == 401:
                    result["error"] = f"Authentication failed: {error_msg}"
                    return result
                elif response.status_code == 403:
                    result["error"] = f"Permission denied: {error_msg}"
                    return result

        except requests.exceptions.Timeout:
            continue
        except requests.exceptions.RequestException as e:
            logger.warning(f"Request exception for {api_url}: {str(e)}")
            continue
        except Exception as e:
            logger.warning(f"Unexpected error for {api_url}: {str(e)}")
            continue

    # If we get here, all endpoints failed
    if not result["error"]:
        result["error"] = f"All endpoints failed. Tried {len(endpoints_to_try)} endpoints."

    logger.error(f"Failed to fetch call status for {call_id}: {result['error']}")
    return result


def sync_call_status_from_api(call_attempt: CallAttempt) -> bool:
    """
    Sync call status from ElevenLabs API if webhook hasn't updated it.

    Args:
        call_attempt: CallAttempt instance to update

    Returns:
        True if successfully synced, False otherwise
    """
    if not call_attempt.external_call_id:
        logger.warning(f"Call attempt {call_attempt.id} has no external_call_id")
        return False

    # Only sync if call is still in progress or initiated
    if call_attempt.status not in [
        CallStatus.INITIATED,
        CallStatus.IN_PROGRESS,
        CallStatus.SCHEDULED,
    ]:
        return False  # Already completed/failed

    # Fetch from API
    call_data = fetch_call_status_from_elevenlabs(call_attempt.external_call_id)

    if not call_data["success"]:
        logger.warning(
            f"Failed to fetch call status for {call_attempt.external_call_id}: {call_data.get('error')}"
        )
        return False

    # Update call attempt
    updated = False

    if call_data.get("transcript"):
        call_attempt.transcript = call_data["transcript"]
        updated = True

    if call_data.get("summary"):
        call_attempt.summary = call_data["summary"]
        updated = True

    if call_data.get("summary_title"):
        call_attempt.summary_title = call_data["summary_title"]
        updated = True

    if call_data.get("recording_url"):
        call_attempt.recording_url = call_data["recording_url"]
        updated = True

    # Update status
    status = call_data.get("status", "").upper()
    status_mapping = {
        "DONE": CallStatus.COMPLETED,
        "COMPLETED": CallStatus.COMPLETED,
        "FAILED": CallStatus.FAILED,
        "NO_ANSWER": CallStatus.NO_ANSWER,
    }

    if status in status_mapping:
        new_status = status_mapping[status]
        if call_attempt.status != new_status:
            call_attempt.status = new_status
            updated = True

    if updated:
        call_attempt.save()

        # Update meeting if completed.
        # NOTE: `call_attempt.meeting` is None for the Visit-based pipeline
        # (process_visit_pre_calls / process_visit_post_calls). The Visit-flow
        # equivalents of these meeting-level updates happen elsewhere:
        #   * `visit.status` is moved to PRE_CALL_DONE / POST_CALL_DONE in
        #     process_visit_*_calls right after a successful trigger, and again
        #     in the webhook handler.
        #   * Pipedrive sync for Visit-flow goes via the post-call analysis
        #     path that reads `visit.client` directly (not `meeting`).
        # So we skip both blocks when meeting is None — they are no-ops, not
        # bugs, for the new pipeline.
        if call_attempt.status == CallStatus.COMPLETED and call_attempt.meeting:
            meeting = call_attempt.meeting
            if call_attempt.phase == CallPhase.PRE_MEETING:
                meeting.is_pre_call_completed = True
            elif call_attempt.phase == CallPhase.POST_MEETING:
                meeting.is_post_call_completed = True
            meeting.save()

            # Trigger Pipedrive sync for post-meeting calls
            if call_attempt.phase == CallPhase.POST_MEETING:
                # Use summary if available, fallback to transcript
                note_text = (
                    call_attempt.summary if call_attempt.summary else call_attempt.transcript
                )
                if note_text:
                    try:
                        sync_note_to_pipedrive(
                            deal_id=None,  # Will be determined from meeting (now uses domain-based search)
                            text=note_text,
                            meeting=meeting,
                        )
                    except Exception as e:
                        logger.error(
                            f"Failed to sync to Pipedrive after API sync: {e}", exc_info=True
                        )
                        log_activity(
                            meeting=meeting,
                            action="Pipedrive sync failed after API sync",
                            details={"error": str(e)},
                            level=LogLevel.ERROR,
                        )

        # Handle pre-meeting call failure: create -30 call if -60 failed.
        # This retry strategy is Meeting-flow specific. The Visit flow uses
        # `MAX_CALL_ATTEMPTS_PER_PHASE` caps managed in process_visit_pre_calls,
        # so skip this whole block when meeting is None.
        if (
            call_attempt.meeting
            and call_attempt.phase == CallPhase.PRE_MEETING
            and call_attempt.status in [CallStatus.NO_ANSWER, CallStatus.FAILED]
            and call_attempt.scheduled_offset_minutes == PRE_MEETING_OFFSETS[0]
        ):  # -60 minutes
            # Check if -30 call doesn't exist yet
            existing_30 = CallAttempt.objects.filter(
                meeting=call_attempt.meeting,
                phase=CallPhase.PRE_MEETING,
                scheduled_offset_minutes=PRE_MEETING_OFFSETS[1],  # -30 minutes
            ).exists()

            if not existing_30 and call_attempt.meeting.start_time > timezone.now():
                # Create -30 minute call attempt
                scheduled_time = call_attempt.meeting.start_time + timedelta(
                    minutes=PRE_MEETING_OFFSETS[1]
                )
                CallAttempt.objects.create(
                    meeting=call_attempt.meeting,
                    phase=CallPhase.PRE_MEETING,
                    scheduled_offset_minutes=PRE_MEETING_OFFSETS[1],
                    scheduled_time=scheduled_time,
                    status=CallStatus.SCHEDULED,
                )
                log_activity(
                    meeting=call_attempt.meeting,
                    user=_ca_user(call_attempt),
                    action="Created -30 minute retry call after -60 call failed",
                    details={
                        "failed_call_id": call_attempt.id,
                        "failed_status": call_attempt.status,
                    },
                )

        log_activity(
            meeting=call_attempt.meeting,
            user=_ca_user(call_attempt),
            action="Call status synced from API",
            details={
                "call_id": call_attempt.external_call_id,
                "status": call_attempt.status,
                "has_transcript": bool(call_data.get("transcript")),
            },
        )
        return True

    return False


# ============================================================================
# ElevenLabs Conversational AI Integration Service
# ============================================================================
#
# The previous version of this file shipped a `get_elevenlabs_webhook_config`
# / `update_elevenlabs_webhook` pair. Both were speculative — the doc strings
# admitted the endpoints they hit were "placeholder[s] ... to be updated when
# ElevenLabs API documentation is available." They were only ever called from
# the `NgrokWebhookStatusView` (a dev dashboard) and the `detect_ngrok`
# management command, both of which have been removed. Removing the
# placeholder functions too — the real webhook URL is configured manually in
# the ElevenLabs dashboard, which is also what the docstrings ended up
# instructing operators to do as a fallback.
# Note: Twilio number must be configured in ElevenLabs dashboard.
# ElevenLabs handles all Twilio operations internally.

_RO_MONTHS = [
    "ianuarie",
    "februarie",
    "martie",
    "aprilie",
    "mai",
    "iunie",
    "iulie",
    "august",
    "septembrie",
    "octombrie",
    "noiembrie",
    "decembrie",
]


def format_prompt_for_visit(template: str, visit, phase: str = "pre") -> str:
    """Substitute {tokens} in a visit prompt with real values from the visit.

    Available tokens (Romanian-friendly):
      {agent_first_name}   - Visit.agent.first_name (or username)
      {agent_full_name}    - Visit.agent.get_full_name()
      {agent_phone}        - Visit.agent.phone_number
      {client_name}        - Visit.client.name
      {client_status}      - "client nou" or "client existent" (lowercase)
      {client_industry}    - Visit.client.industry
      {visit_date}         - e.g. "28 mai 2026" (Romanian month names)
      {visit_time}         - e.g. "11:00"
      {visit_duration}     - e.g. "60 de minute"
      {visit_title}        - Visit.title
      {methodology_name}   - Visit.methodology.name
      {manager_notes}      - Visit.manager_notes (may be long)
      {pre_call_summary}   - For phase='post', the latest pre-call's Romanian
                             summary. For phase='pre', empty (or stub).

    Unknown tokens are left as-is so the prompt remains readable if it
    references one we don't have data for.
    """
    if not template:
        return template

    agent = visit.agent
    client = visit.client
    methodology = visit.methodology

    visit_date = ""
    visit_time = ""
    visit_duration = ""
    if visit.start_time:
        st = visit.start_time
        visit_date = f"{st.day} {_RO_MONTHS[st.month - 1]} {st.year}"
        visit_time = st.strftime("%H:%M")
    if visit.start_time and visit.end_time:
        minutes = int((visit.end_time - visit.start_time).total_seconds() // 60)
        if minutes > 0:
            visit_duration = f"{minutes} de minute"

    pre_call_summary = ""
    if phase == "post":
        try:
            from voice.constants import CallPhase, CallStatus

            latest_pre = (
                CallAttempt.objects.filter(
                    visit=visit, phase=CallPhase.PRE_MEETING, status=CallStatus.COMPLETED
                )
                .exclude(summary="")
                .order_by("-created_at")
                .first()
            )
            if latest_pre and latest_pre.summary:
                pre_call_summary = latest_pre.summary.strip()
        except Exception as e:
            logger.warning(f"Could not load pre-call summary for visit {visit.id}: {e}")
    if not pre_call_summary:
        pre_call_summary = "(Nu există încă un sumar de pre-call pentru această vizită.)"

    client_status_label = ""
    if client and client.status:
        client_status_label = (client.get_status_display() or "").lower()

    tokens = {
        "{agent_first_name}": (agent.first_name or agent.username or "") if agent else "",
        "{agent_full_name}": (agent.get_full_name() or agent.username or "") if agent else "",
        "{agent_phone}": (agent.phone_number or "") if agent else "",
        "{client_name}": client.name if client else "",
        "{client_status}": client_status_label,
        "{client_industry}": (client.industry or "") if client else "",
        "{visit_date}": visit_date,
        "{visit_time}": visit_time,
        "{visit_duration}": visit_duration,
        "{visit_title}": visit.title or "",
        "{methodology_name}": methodology.name if methodology else "",
        "{manager_notes}": (visit.manager_notes or "").strip(),
        "{pre_call_summary}": pre_call_summary,
        # uppercase variant for the CAPS-emphasis lines in the internal context blocks
        "{client_status_upper}": client_status_label.upper(),
    }

    out = template
    for token, value in tokens.items():
        if token in out:
            out = out.replace(token, str(value))
    return out


def format_prompt_with_context(prompt_template: str, meeting) -> str:
    """
    Inject meeting details into the prompt template.

    Args:
        prompt_template: Prompt template with placeholders
        meeting: Meeting instance with context data

    Returns:
        Formatted prompt with meeting details injected
    """
    # Replace placeholders in the prompt template
    formatted_prompt = prompt_template

    # Available context variables
    context = {
        "{customer_name}": meeting.customer_name or "the customer",
        "{meeting_title}": meeting.title,
        "{meeting_start_time}": meeting.start_time.strftime("%B %d, %Y at %I:%M %p"),
        "{meeting_end_time}": meeting.end_time.strftime("%B %d, %Y at %I:%M %p"),
        "{agent_name}": meeting.agent.get_full_name() or meeting.agent.username,
        "{meeting_date}": meeting.start_time.strftime("%B %d, %Y"),
        "{meeting_time}": meeting.start_time.strftime("%I:%M %p"),
    }

    # Replace all placeholders
    for placeholder, value in context.items():
        if placeholder in formatted_prompt:
            formatted_prompt = formatted_prompt.replace(placeholder, str(value))

    return formatted_prompt


def format_first_message_with_context(first_message_template: str, meeting) -> str:
    """
    Inject meeting details into the first message template.
    Uses the same context variables as format_prompt_with_context.

    Args:
        first_message_template: First message template with placeholders
        meeting: Meeting instance with context data

    Returns:
        Formatted first message with meeting details injected
    """
    # Reuse the same formatting logic as system prompt
    return format_prompt_with_context(first_message_template, meeting)


def trigger_agent_call(
    agent_phone: str,
    prompt_text: str,
    context_data: dict[str, Any],
    call_attempt: CallAttempt,
    first_message_text: str | None = None,
) -> dict[str, Any]:
    """
    Initiate a voice call using ElevenLabs Conversational AI.

    Note: Twilio number must be configured in ElevenLabs dashboard.
    ElevenLabs handles all Twilio operations internally.

    Prompt Overrides:
    - If prompt_text is provided and ELEVENLABS_USE_PROMPT_OVERRIDES=True,
      the prompt will be sent as an override to customize the agent's behavior for this call.
    - If first_message_text is provided, it will be sent as the first message override.
    - Requires "Allow Overrides" to be enabled in the agent's Security settings in ElevenLabs dashboard.
    - If overrides are not enabled, the call will use the agent's default prompt.

    Args:
        agent_phone: Agent's phone number in E.164 format (recipient of the call)
        prompt_text: System prompt for the AI agent (will be sent as override if configured)
        context_data: Additional context data for the call (for logging/debugging)
        call_attempt: CallAttempt instance to update
        first_message_text: First message/greeting for the AI agent (optional, will be sent as override if provided)

    Returns:
        Dictionary with call result: {'success': bool, 'call_id': str, 'error': str}
    """
    import requests
    from decouple import config

    result = {"success": False, "call_id": None, "error": None}

    # Validate phone number
    formatted_phone = format_phone_number(agent_phone)
    if not formatted_phone:
        error_msg = f"Invalid phone number format: {agent_phone}"
        result["error"] = error_msg
        log_activity(
            meeting=call_attempt.meeting,
            user=_ca_user(call_attempt),
            action="Call failed - invalid phone number",
            details={"phone_number": agent_phone, "error": error_msg},
            level=LogLevel.ERROR,
        )
        call_attempt.status = CallStatus.FAILED
        call_attempt.save()
        return result

    # Get ElevenLabs API key and configuration
    elevenlabs_api_key = config("ELEVENLABS_API_KEY", default="")
    elevenlabs_agent_id = config("ELEVENLABS_AGENT_ID", default="")
    elevenlabs_phone_number_id = config("ELEVENLABS_PHONE_NUMBER_ID", default="")

    if not elevenlabs_api_key:
        error_msg = "Missing ElevenLabs API key"
        result["error"] = error_msg
        log_activity(
            meeting=call_attempt.meeting,
            user=_ca_user(call_attempt),
            action="Call failed - missing ElevenLabs API key",
            details={"error": error_msg},
            level=LogLevel.ERROR,
        )
        call_attempt.status = CallStatus.FAILED
        call_attempt.save()
        return result

    if not elevenlabs_agent_id:
        error_msg = "Missing ElevenLabs Agent ID"
        result["error"] = error_msg
        log_activity(
            meeting=call_attempt.meeting,
            user=_ca_user(call_attempt),
            action="Call failed - missing ElevenLabs Agent ID",
            details={"error": error_msg},
            level=LogLevel.ERROR,
        )
        call_attempt.status = CallStatus.FAILED
        call_attempt.save()
        return result

    if not elevenlabs_phone_number_id:
        error_msg = "Missing ElevenLabs Phone Number ID"
        result["error"] = error_msg
        log_activity(
            meeting=call_attempt.meeting,
            user=_ca_user(call_attempt),
            action="Call failed - missing ElevenLabs Phone Number ID",
            details={"error": error_msg},
            level=LogLevel.ERROR,
        )
        call_attempt.status = CallStatus.FAILED
        call_attempt.save()
        return result

    try:
        # Note: Using requests directly as ElevenLabs SDK may not have this endpoint
        # API endpoint: POST https://api.elevenlabs.io/v1/convai/twilio/outbound-call

        # Create call attempt record and mark as initiated
        call_attempt.status = CallStatus.INITIATED
        call_attempt.executed_at = timezone.now()
        call_attempt.save()

        # Note: We'll log after building the payload to include prompt info

        # Make API call to ElevenLabs outbound call endpoint
        api_url = "https://api.elevenlabs.io/v1/convai/twilio/outbound-call"
        headers = {"Content-Type": "application/json", "xi-api-key": elevenlabs_api_key}

        # Build payload
        payload = {
            "agent_id": elevenlabs_agent_id,
            "agent_phone_number_id": elevenlabs_phone_number_id,
            "to_number": formatted_phone,
        }

        # ElevenLabs Override Behavior:
        # - If overrides are ENABLED in ElevenLabs dashboard: providing an override is optional
        #   * If we provide an override → it's used
        #   * If we don't provide an override → ElevenLabs uses default values from dashboard
        # - If overrides are DISABLED in ElevenLabs dashboard: providing an override will throw an error
        #
        # Therefore: We only include override in payload if we have actual values to override.
        # This allows ElevenLabs to use defaults when we don't provide overrides (if enabled),
        # and return an error if we provide overrides when they're disabled.
        #
        # Only include override in payload if we have actual values to override
        # If prompt_text is empty/None, we don't send override → ElevenLabs uses default (if overrides enabled)
        if prompt_text and prompt_text.strip():
            prompt_to_send = prompt_text.strip()

            # According to ElevenLabs documentation for /v1/convai/twilio/outbound-call:
            # Overrides must be wrapped in conversation_initiation_client_data
            agent_config = {"prompt": {"prompt": prompt_to_send}}

            # Add first_message override only if provided (optional field)
            if first_message_text and first_message_text.strip():
                agent_config["first_message"] = first_message_text.strip()

            payload["conversation_initiation_client_data"] = {
                "conversation_config_override": {"agent": agent_config}
            }

        # Make the API call
        response = requests.post(api_url, headers=headers, json=payload, timeout=30)

        # Handle API response
        if response.status_code == 200:
            call_data = response.json()

            # Check if response contains any warnings
            if isinstance(call_data, dict) and "warnings" in call_data:
                logger.warning(f"ElevenLabs returned warnings: {call_data['warnings']}")

            # Extract call_id from response (may be 'call_id', 'id', or 'call_sid')
            call_id = (
                call_data.get("call_id")
                or call_data.get("id")
                or call_data.get("call_sid")
                or call_data.get("conversation_id")
            )

            if call_id:
                result["success"] = True
                result["call_id"] = call_id
                call_attempt.external_call_id = call_id
                call_attempt.status = CallStatus.IN_PROGRESS
                call_attempt.save()

                # Log successful call initiation
                log_activity(
                    meeting=call_attempt.meeting,
                    user=_ca_user(call_attempt),
                    action="Call successfully initiated via ElevenLabs API",
                    details={
                        "call_id": call_id,
                        "phone_number": formatted_phone,
                        "phase": call_attempt.phase,
                        "offset_minutes": call_attempt.scheduled_offset_minutes,
                        "used_prompt_override": bool(prompt_text and prompt_text.strip()),
                        "has_first_message": bool(
                            first_message_text and first_message_text.strip()
                        ),
                    },
                    level=LogLevel.INFO,
                )
            else:
                error_msg = (
                    f"ElevenLabs API returned success but no call_id in response: {call_data}"
                )
                result["error"] = error_msg
                logger.error(error_msg)
                log_activity(
                    meeting=call_attempt.meeting,
                    user=_ca_user(call_attempt),
                    action="Call failed - no call_id in response",
                    details={"error": error_msg, "response": str(call_data)},
                    level=LogLevel.ERROR,
                )
                call_attempt.status = CallStatus.FAILED
                call_attempt.save()
        else:
            # Handle API errors
            try:
                error_data = response.json()
                error_detail = error_data.get(
                    "detail", error_data.get("message", error_data.get("error", "Unknown error"))
                )
                error_msg = f"ElevenLabs API error ({response.status_code}): {error_detail}"

                # Check if error is related to overrides not being enabled
                error_lower = str(error_detail).lower()
                error_text_lower = response.text.lower()

                if (
                    "override" in error_lower
                    or "override" in error_text_lower
                    or "permission" in error_lower
                    or "security" in error_lower
                    or "not allowed" in error_lower
                    or "disabled" in error_lower
                ):
                    override_error_msg = (
                        "Prompt overrides are not enabled for this agent. "
                        "Please enable 'Allow Overrides' in the agent's Security settings "
                        "in the ElevenLabs dashboard."
                    )
                    error_msg = f"{error_msg}. {override_error_msg}"

            except (ValueError, KeyError, json.JSONDecodeError):
                error_msg = f"ElevenLabs API error ({response.status_code}): {response.text[:200]}"

            result["error"] = error_msg
            logger.error(f"ElevenLabs API call failed: {error_msg}")

            log_activity(
                meeting=call_attempt.meeting,
                user=_ca_user(call_attempt),
                action="Call failed - ElevenLabs API error",
                details={
                    "error": error_msg,
                    "status_code": response.status_code,
                    "phone_number": formatted_phone,
                },
                level=LogLevel.ERROR,
            )

            call_attempt.status = CallStatus.FAILED
            call_attempt.save()

    except Exception as e:
        error_msg = f"Failed to initiate call: {str(e)}"
        result["error"] = error_msg
        logger.error(error_msg, exc_info=True)

        log_activity(
            meeting=call_attempt.meeting,
            user=_ca_user(call_attempt),
            action="Call initiation failed",
            details={"error": error_msg, "phone_number": formatted_phone},
            level=LogLevel.ERROR,
        )

        call_attempt.status = CallStatus.FAILED
        call_attempt.save()

    return result


# ============================================================================
# Visit-aware EL trigger (used by the Call Now button on Visit Detail).
# Bypasses the legacy meeting-keyed trigger_agent_call; works with Visit
# directly. The prompt is taken verbatim from visit.pre_call_prompt or
# visit.post_call_prompt — no placeholder interpolation.
# ============================================================================


def trigger_visit_call(visit, phase: str) -> dict[str, Any]:
    """Initiate an EL outbound call for a Visit and phase ('pre' or 'post').

    - Reads the pre-rendered prompt directly from visit.pre_call_prompt
      or visit.post_call_prompt.
    - Picks the agent's phone from visit.agent.phone_number.
    - Uses settings.ELEVENLABS_AGENT_ID as the shared EL agent.
    - Creates a CallAttempt(visit=visit, meeting=None, phase=..., ...).

    Returns: {'success': bool, 'call_id': str|None, 'error': str|None}.
    """
    import requests
    from decouple import config

    from voice.constants import CallPhase

    result = {"success": False, "call_id": None, "error": None}

    # Phase mapping
    if phase == "pre":
        prompt_text = visit.pre_call_prompt
        first_message_text = visit.pre_call_first_message or ""
        call_phase = CallPhase.PRE_MEETING
    elif phase == "post":
        prompt_text = visit.post_call_prompt
        first_message_text = visit.post_call_first_message or ""
        call_phase = CallPhase.POST_MEETING
    else:
        result["error"] = f"Invalid phase '{phase}'. Expected 'pre' or 'post'."
        return result

    # Substitute {tokens} with real visit data (agent name, client, time,
    # methodology, and — critically for post-call — the pre-call summary).
    prompt_text = format_prompt_for_visit(prompt_text or "", visit, phase=phase)
    first_message_text = format_prompt_for_visit(first_message_text or "", visit, phase=phase)

    if not prompt_text or not prompt_text.strip():
        result["error"] = (
            f"{phase.title()}-call prompt is empty on visit #{visit.id}. "
            f"Paste it on the Visit Detail page first."
        )
        return result

    # Validate agent phone
    if not visit.agent or not visit.agent.phone_number:
        result["error"] = f"Visit #{visit.id} has no agent phone number on file."
        return result
    formatted_phone = format_phone_number(visit.agent.phone_number)
    if not formatted_phone:
        result["error"] = f"Agent phone '{visit.agent.phone_number}' is not a valid E.164 number."
        return result

    # Validate env vars
    api_key = config("ELEVENLABS_API_KEY", default="")
    agent_id = config("ELEVENLABS_AGENT_ID", default="")
    phone_number_id = config("ELEVENLABS_PHONE_NUMBER_ID", default="")
    missing = [
        name
        for name, val in (
            ("ELEVENLABS_API_KEY", api_key),
            ("ELEVENLABS_AGENT_ID", agent_id),
            ("ELEVENLABS_PHONE_NUMBER_ID", phone_number_id),
        )
        if not val
    ]
    if missing:
        result["error"] = f"Missing env vars: {', '.join(missing)}"
        return result

    # Create CallAttempt row (visit-linked, no meeting)
    call_attempt = CallAttempt.objects.create(
        visit=visit,
        meeting=None,
        phase=call_phase,
        scheduled_offset_minutes=0,
        scheduled_time=timezone.now(),
        executed_at=timezone.now(),
        status=CallStatus.INITIATED,
    )

    # Build EL payload — matches recruitflow's payload exactly. EL requires
    # both `prompt` and `first_message` keys present for the override to be
    # honored; omitting first_message causes EL to silently fall back to the
    # agent's dashboard-configured default prompt.
    payload = {
        "agent_id": agent_id,
        "agent_phone_number_id": phone_number_id,
        "to_number": formatted_phone,
        "conversation_initiation_client_data": {
            "conversation_config_override": {
                "agent": {
                    "prompt": {"prompt": prompt_text.strip()},
                    "first_message": first_message_text.strip(),
                },
            },
        },
    }

    api_url = "https://api.elevenlabs.io/v1/convai/twilio/outbound-call"
    headers = {
        "Content-Type": "application/json",
        "xi-api-key": api_key,
    }

    try:
        response = requests.post(api_url, headers=headers, json=payload, timeout=30)
    except requests.exceptions.RequestException as e:
        call_attempt.status = CallStatus.FAILED
        call_attempt.save()
        result["error"] = f"EL request failed: {e}"
        return result

    if response.status_code == 200:
        data = response.json()
        call_id = (
            data.get("conversation_id")
            or data.get("call_id")
            or data.get("id")
            or data.get("call_sid")
        )
        if call_id:
            call_attempt.external_call_id = call_id
            call_attempt.status = CallStatus.IN_PROGRESS
            call_attempt.save()
            result["success"] = True
            result["call_id"] = call_id
            return result
        call_attempt.status = CallStatus.FAILED
        call_attempt.save()
        result["error"] = f"EL returned 200 but no call_id in response: {data}"
        return result

    # Non-200
    try:
        err_data = response.json()
        err_detail = (
            err_data.get("detail")
            or err_data.get("message")
            or err_data.get("error")
            or str(err_data)
        )
    except Exception:
        err_detail = response.text[:200]
    call_attempt.status = CallStatus.FAILED
    call_attempt.save()
    result["error"] = f"EL API error ({response.status_code}): {err_detail}"
    return result
