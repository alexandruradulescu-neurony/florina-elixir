"""
Webhook views for external integrations (ElevenLabs, Twilio).
"""

import json
import logging
from contextlib import suppress

from django.http import HttpResponse, JsonResponse
from django.utils.decorators import method_decorator
from django.views import View
from django.views.decorators.csrf import csrf_exempt

from .constants import CallPhase, CallStatus, LogLevel
from .models import CallAttempt, GoogleCalendarWatch
from .selectors import get_call_attempt_by_external_id
from .services import handle_google_calendar_notification, log_activity

logger = logging.getLogger(__name__)


@method_decorator(csrf_exempt, name="dispatch")
class ElevenLabsWebhookView(View):
    """
    Webhook endpoint for ElevenLabs call status updates.
    Receives call completion, transcript, and status information.

    Expected webhook format from ElevenLabs:
    {
        "type": "post_call_transcription",
        "data": {
            "agent_id": "...",
            "conversation_id": "...",  # This is the call_id
            "status": "done",
            "transcript": {
                "turns": [
                    {"role": "agent", "content": "..."},
                    {"role": "user", "content": "..."}
                ]
            },
            "metadata": {
                "recording_url": "...",
                ...
            },
            "analysis": {...}
        },
        "event_timestamp": 1234567890
    }
    """

    def post(self, request):
        """Handle ElevenLabs webhook POST request."""
        # ── Authenticate the request before any processing (fail-closed) ──
        from .webhook_security import (
            get_elevenlabs_webhook_secret,
            require_signature,
            verify_elevenlabs_signature,
        )

        if require_signature():
            secret = get_elevenlabs_webhook_secret()
            if not secret:
                logger.critical(
                    "ElevenLabs webhook secret not configured — rejecting request "
                    "(set ELEVENLABS_WEBHOOK_SECRET or WEBHOOK_REQUIRE_SIGNATURE=False)."
                )
                return JsonResponse(
                    {"error": "Webhook signature verification not configured"}, status=503
                )
            sig_header = request.headers.get("ElevenLabs-Signature", "")
            ok, reason = verify_elevenlabs_signature(sig_header, request.body, secret)
            if not ok:
                logger.warning(f"Rejected ElevenLabs webhook: signature {reason}")
                return JsonResponse({"error": "Invalid or missing signature"}, status=401)

        try:
            # Parse webhook payload
            if request.content_type == "application/json":
                payload = json.loads(request.body)
            else:
                payload = request.POST.dict()

            logger.info("ElevenLabs webhook received")

            # ElevenLabs webhook structure:
            # - Top level has "type" and "data"
            # - "data" contains conversation_id, status, transcript, metadata
            webhook_type = payload.get("type", "")
            data = payload.get("data", {})

            # Extract call information from data object
            # Try multiple possible fields for call_id
            call_id = (
                data.get("conversation_id")
                or data.get("call_id")
                or payload.get("call_id")
                or payload.get("id")
                or data.get("id")
            )

            # Extract status from data object
            status = data.get("status", "").upper() or payload.get("status", "").upper()

            # Extract transcript - ElevenLabs sends it in a structured format
            transcript_data = data.get("transcript", {})

            if isinstance(transcript_data, list):
                # ElevenLabs sends transcript as a list of turn objects
                transcript_text = self._extract_transcript_from_list(transcript_data)
            elif isinstance(transcript_data, dict):
                transcript_text = self._extract_transcript_text(transcript_data)
            elif isinstance(transcript_data, str):
                transcript_text = transcript_data
            else:
                transcript_text = None

            # Fallback to old format if transcript not in data
            if not transcript_text:
                transcript_text = payload.get("transcript") or payload.get(
                    "conversation_transcript"
                )

            if not transcript_text:
                logger.warning(f"No transcript found in webhook for call_id: {call_id}")

            # Extract summary from analysis data
            analysis = data.get("analysis", {})
            summary = None
            summary_title = None
            if isinstance(analysis, dict):
                summary = analysis.get("transcript_summary") or analysis.get("summary")
                summary_title = analysis.get("call_summary_title")

            # Extract recording URL from metadata
            metadata = data.get("metadata", {}) or payload.get("metadata", {})
            recording_url = (
                metadata.get("recording_url")
                or metadata.get("audio_url")
                or data.get("recording_url")
                or payload.get("recording_url")
                or payload.get("audio_url")
            )

            if not call_id:
                logger.warning("ElevenLabs webhook missing conversation_id/call_id")
                # Still return 200 to prevent retries
                return JsonResponse(
                    {"status": "received", "error": "Missing conversation_id"}, status=200
                )

            # Find the call attempt
            call_attempt = get_call_attempt_by_external_id(call_id)

            if not call_attempt:
                # Try to find by metadata if call_id doesn't match
                if metadata and "call_attempt_id" in metadata:
                    with suppress(CallAttempt.DoesNotExist):
                        call_attempt = CallAttempt.objects.get(id=metadata["call_attempt_id"])

                if not call_attempt:
                    logger.warning(f"Call attempt not found for conversation_id: {call_id}")
                    # Still return 200 to prevent retries
                    return JsonResponse(
                        {"status": "received", "message": "Call attempt not found"}, status=200
                    )

            # Update call attempt with webhook data
            if transcript_text:
                call_attempt.transcript = transcript_text
                logger.info(
                    f"Saved transcript for call {call_attempt.id} ({len(transcript_text)} chars)"
                )

            if summary:
                call_attempt.summary = summary
                logger.info(f"Saved summary for call {call_attempt.id} ({len(summary)} chars)")

            if summary_title:
                call_attempt.summary_title = summary_title

            if recording_url:
                call_attempt.recording_url = recording_url

            # Map ElevenLabs status to our CallStatus
            # ElevenLabs uses: "done", "in_progress", "failed", etc.
            status_mapping = {
                "DONE": CallStatus.COMPLETED,
                "COMPLETED": CallStatus.COMPLETED,
                "ANSWERED": CallStatus.COMPLETED,
                "NO_ANSWER": CallStatus.NO_ANSWER,
                "BUSY": CallStatus.NO_ANSWER,
                "FAILED": CallStatus.FAILED,
                "CANCELLED": CallStatus.FAILED,
                "CANCELED": CallStatus.FAILED,
            }

            if status in status_mapping:
                call_attempt.status = status_mapping[status]
            elif status == "IN_PROGRESS" or status == "RINGING" or status == "IN_PROGRESS":
                call_attempt.status = CallStatus.IN_PROGRESS
            else:
                # Default to completed if transcript exists or status is "done"
                if transcript_text or status.lower() == "done":
                    call_attempt.status = CallStatus.COMPLETED
                else:
                    call_attempt.status = CallStatus.FAILED

            call_attempt.save()

            # ─── Romanian summary + structured analysis on completed calls ───
            # Always runs for any COMPLETED call with a transcript. Overwrites the
            # English summary ElevenLabs sends in its analysis block.
            # Failures are logged but never break the webhook response.
            if (
                call_attempt.status == CallStatus.COMPLETED
                and call_attempt.transcript
                and call_attempt.transcript.strip()
            ):
                try:
                    from voice.services.llm import (
                        analyze_post_call,
                        summarize_call_transcript_ro,
                    )

                    visit = call_attempt.visit
                    is_post = call_attempt.phase == CallPhase.POST_MEETING
                    phase_str = "post" if is_post else "pre"

                    # Build context blob for Claude.
                    original_prompt = ""
                    visit_ctx_parts = []
                    if visit:
                        original_prompt = (
                            visit.post_call_prompt if is_post else visit.pre_call_prompt
                        ) or ""
                        if visit.client:
                            visit_ctx_parts.append(
                                f"Client: {visit.client.name} "
                                f"({visit.client.industry or 'industrie necunoscută'}) — "
                                f"{visit.client.get_status_display()}"
                            )
                        if visit.agent:
                            agent_name = visit.agent.get_full_name() or visit.agent.username
                            visit_ctx_parts.append(f"Agent: {agent_name}")
                        if visit.methodology:
                            visit_ctx_parts.append(f"Metodologie: {visit.methodology.name}")
                        if visit.title:
                            visit_ctx_parts.append(f"Vizită: {visit.title}")
                    visit_context = " | ".join(visit_ctx_parts)

                    # Post-call: run full structured analysis. The analysis 'summary'
                    # is already Romanian and CRM-ready, so we reuse it for .summary
                    # to avoid a second Claude call.
                    ro_summary = None
                    if is_post:
                        # Inject the latest pre-call summary so Claude can
                        # cross-check claims (consistency_check field).
                        pre_call_summary_for_analysis = ""
                        try:
                            from .models import CallAttempt as _CA

                            latest_pre = (
                                _CA.objects.filter(
                                    visit=visit,
                                    phase=CallPhase.PRE_MEETING,
                                    status=CallStatus.COMPLETED,
                                )
                                .exclude(summary="")
                                .order_by("-created_at")
                                .first()
                            )
                            if latest_pre and latest_pre.summary:
                                pre_call_summary_for_analysis = latest_pre.summary.strip()
                        except Exception as e:
                            logger.warning(f"Could not load pre-call summary for analysis: {e}")

                        analysis = analyze_post_call(
                            transcript=call_attempt.transcript,
                            post_call_prompt=original_prompt,
                            visit_context=visit_context,
                            pre_call_summary=pre_call_summary_for_analysis,
                        )
                        if analysis:
                            call_attempt.analysis = analysis
                            ro_summary = analysis.get("summary") or None
                            logger.info(f"Claude analysis saved for CallAttempt #{call_attempt.id}")
                        else:
                            logger.warning(
                                f"Claude analysis returned None for CallAttempt #{call_attempt.id}"
                            )

                    # Pre-call (or post-call without usable analysis summary):
                    # generate a 2-4 sentence Romanian summary.
                    if not ro_summary:
                        ro_summary = summarize_call_transcript_ro(
                            transcript=call_attempt.transcript,
                            phase=phase_str,
                            visit_context=visit_context,
                            original_prompt=original_prompt,
                        )

                    if ro_summary:
                        call_attempt.summary = ro_summary.strip()
                        logger.info(
                            f"Romanian summary saved for CallAttempt #{call_attempt.id} "
                            f"({len(ro_summary)} chars)"
                        )

                    # Persist whatever changed.
                    update_fields = ["summary"]
                    if is_post:
                        update_fields.append("analysis")
                    call_attempt.save(update_fields=update_fields)
                except Exception as e:
                    logger.error(
                        f"Romanian summary / analysis failed for CallAttempt "
                        f"#{call_attempt.id}: {e}",
                        exc_info=True,
                    )

            # ─── Advance Visit.status on visit-linked completed calls ───
            # Pre-call completed → PRE_CALL_DONE (if still PLANNED).
            # Post-call completed → POST_CALL_DONE (regardless of intermediate state).
            if call_attempt.status == CallStatus.COMPLETED and call_attempt.visit:
                from .constants import VisitStatus as VS

                visit = call_attempt.visit
                new_status = None
                if call_attempt.phase == CallPhase.PRE_MEETING:
                    if visit.status == VS.PLANNED:
                        new_status = VS.PRE_CALL_DONE
                elif call_attempt.phase == CallPhase.POST_MEETING and visit.status in (
                    VS.PLANNED,
                    VS.PRE_CALL_DONE,
                    VS.IN_PROGRESS,
                ):
                    new_status = VS.POST_CALL_DONE
                if new_status:
                    visit.status = new_status
                    visit.save(update_fields=["status", "updated_at"])
                    logger.info(f"Visit #{visit.id} advanced to {new_status}")

                # Closed-loop: after a successful post-call debrief, distill the
                # new transcript / analysis into Client.lessons_learned so future
                # pre-call assemblies are smarter. Failures are logged but never
                # raised — the webhook must always acknowledge the call quickly
                # and the debrief itself is the user-visible success.
                #
                # (Previously this branch re-ran `assemble_post_call` to bake the
                # late-arriving transcript into the prompt "for retry dials". But
                # the scheduler only retries FAILED/NO_ANSWER attempts, never a
                # COMPLETED post-meeting — the re-assembly was ~4k tokens of
                # wasted Claude spend per real post-call. Dropped in PR 5.)
                if (
                    call_attempt.phase == CallPhase.POST_MEETING
                    and call_attempt.status == CallStatus.COMPLETED
                    and call_attempt.transcript
                ):
                    try:
                        from voice.models import GenerationRun
                        from voice.services.lessons import distill_lessons

                        # Pull a structured outcome signal from the analyze_post_call
                        # JSON if present; otherwise fall back to the empty string
                        # (the distill prompt tolerates that). Best-effort — never
                        # block the webhook on a missing key.
                        outcome = ""
                        if isinstance(call_attempt.analysis, dict):
                            for k in ("objective_attained", "outcome", "status_label"):
                                v = call_attempt.analysis.get(k)
                                if isinstance(v, str) and v:
                                    outcome = v
                                    break

                        distill_lessons(
                            client=visit.client,
                            new_post_call_summary=visit.post_call_summary
                            or call_attempt.summary
                            or call_attempt.transcript[:2000],
                            evaluation_outcome=outcome,
                            triggered_by=GenerationRun.TriggeredBy.END_OF_MEETING,
                        )
                    except Exception:
                        logger.exception(
                            "LESSONS_DISTILL chain failed for visit=%s (debrief still complete)",
                            visit.id,
                        )

            # PR Y2b: the Meeting-flow webhook bookkeeping (is_pre/post_call_-
            # completed flags, Meeting-typed Pipedrive sync, -60→-30 retry
            # cloning, Meeting-anchored ActivityLog rows) was removed along
            # with the Meeting model. Visit-flow handles every equivalent:
            #   * Visit status moves to PRE_CALL_DONE / POST_CALL_DONE in
            #     `process_visit_*_calls` after a successful trigger and is
            #     reasserted here via the visit-linked path higher up in this
            #     handler.
            #   * Pipedrive sync runs from `voice/tasks.py` post-call task
            #     via the CRM provider abstraction (`visit.crm_deal_id`).
            #   * Retry caps are governed by `MAX_CALL_ATTEMPTS_PER_PHASE`
            #     in `process_visit_pre_calls` rather than a hard-coded
            #     -60 → -30 clone.
            if call_attempt.status != CallStatus.COMPLETED:
                log_activity(
                    visit=call_attempt.visit,
                    user=call_attempt.agent,
                    action=(
                        f"{call_attempt.get_phase_display()} call "
                        f"{call_attempt.get_status_display()}"
                    ),
                    details={
                        "call_id": call_id,
                        "status": status,
                        "webhook_type": webhook_type,
                    },
                    level=LogLevel.WARNING
                    if call_attempt.status == CallStatus.NO_ANSWER
                    else LogLevel.ERROR,
                )

            return JsonResponse({"status": "success", "call_attempt_id": call_attempt.id})

        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in ElevenLabs webhook: {e}")
            return JsonResponse({"error": "Invalid JSON"}, status=400)
        except Exception as e:
            logger.error(f"Error processing ElevenLabs webhook: {e}", exc_info=True)
            return JsonResponse({"error": "Internal server error"}, status=500)

    def _extract_transcript_text(self, transcript_data: dict) -> str:
        """
        Extract readable transcript text from ElevenLabs transcript structure.

        ElevenLabs transcript structure:
        {
            "turns": [
                {
                    "role": "agent" | "user",
                    "content": "..."
                }
            ]
        }

        Args:
            transcript_data: Transcript dictionary from ElevenLabs

        Returns:
            Formatted transcript text
        """
        if not isinstance(transcript_data, dict):
            return str(transcript_data) if transcript_data else ""

        # Try multiple possible structures
        # Structure 1: turns array
        turns = transcript_data.get("turns", [])

        if turns:
            # Build readable transcript from turns
            transcript_lines = []
            for turn in turns:
                if not isinstance(turn, dict):
                    continue

                role = turn.get("role", "unknown")
                content = turn.get("content", "") or turn.get("text", "") or turn.get("message", "")

                if content:
                    role_label = (
                        "Agent" if role == "agent" else "User" if role == "user" else role.title()
                    )
                    transcript_lines.append(f"{role_label}: {content}")

            return "\n\n".join(transcript_lines) if transcript_lines else ""

        # Structure 2: Direct text fields
        text_fields = ["text", "content", "transcript", "message", "summary"]
        for field in text_fields:
            if field in transcript_data:
                value = transcript_data[field]
                if value:
                    if isinstance(value, str):
                        return value
                    elif isinstance(value, dict):
                        # Recursively extract from nested dict
                        return self._extract_transcript_text(value)
                    else:
                        return str(value)

        # Structure 3: Check for analysis/summary fields
        analysis = transcript_data.get("analysis", {})
        if isinstance(analysis, dict):
            summary = analysis.get("summary") or analysis.get("transcript")
            if summary:
                return str(summary)

        # Structure 4: Last resort - stringify the whole thing
        logger.warning(
            f"Could not extract transcript from dict structure. Available keys: {list(transcript_data.keys())}"
        )
        return str(transcript_data) if transcript_data else ""

    def _extract_transcript_from_list(self, transcript_list: list) -> str:
        """
        Extract readable transcript text from ElevenLabs transcript list format.

        ElevenLabs sometimes sends transcript as a list of turn objects:
        [
            {
                "role": "agent" | "user",
                "message": "...",
                ...
            },
            ...
        ]

        Args:
            transcript_list: List of transcript turn objects from ElevenLabs

        Returns:
            Formatted transcript text
        """
        if not isinstance(transcript_list, list):
            logger.warning(f"Expected list for transcript extraction, got {type(transcript_list)}")
            return ""

        transcript_lines = []
        for turn in transcript_list:
            if not isinstance(turn, dict):
                continue

            role = turn.get("role", "unknown")
            # Try multiple possible message fields
            message = turn.get("message") or turn.get("content") or turn.get("text")

            if message:
                role_label = (
                    "Agent" if role == "agent" else "User" if role == "user" else role.title()
                )
                transcript_lines.append(f"{role_label}: {message}")

        return "\n\n".join(transcript_lines) if transcript_lines else ""

    def get(self, request):
        """Handle GET request for webhook verification (if required)."""
        return JsonResponse({"status": "ok", "message": "ElevenLabs webhook endpoint is active"})


@method_decorator(csrf_exempt, name="dispatch")
class TwilioWebhookView(View):
    """
    Optional webhook endpoint for Twilio call status updates.

    Note: ElevenLabs webhook is the primary source of call status.
    This endpoint is kept for additional tracking/debugging purposes.
    Twilio number should be configured in ElevenLabs dashboard.
    """

    def post(self, request):
        """Handle Twilio webhook POST request."""
        # ── Authenticate the request before any processing (fail-closed) ──
        from .webhook_security import (
            get_twilio_auth_token,
            require_signature,
            verify_twilio_signature,
        )

        if require_signature():
            auth_token = get_twilio_auth_token()
            if not auth_token:
                logger.warning(
                    "Twilio webhook hit but TWILIO_AUTH_TOKEN not configured — "
                    "rejecting (fail-closed)."
                )
                return HttpResponse(status=403)
            signature = request.META.get("HTTP_X_TWILIO_SIGNATURE", "")
            ok, reason = verify_twilio_signature(
                request.build_absolute_uri(), request.POST, signature, auth_token
            )
            if not ok:
                logger.warning(f"Rejected Twilio webhook: signature {reason}")
                return HttpResponse(status=403)

        try:
            # Twilio sends form data, not JSON
            call_sid = request.POST.get("CallSid")
            call_status = request.POST.get("CallStatus")

            logger.info(f"Twilio webhook received: CallSid={call_sid}, Status={call_status}")

            if not call_sid:
                return JsonResponse({"error": "Missing CallSid"}, status=400)

            # Find call attempt by Twilio SID
            call_attempt = get_call_attempt_by_external_id(call_sid)

            if call_attempt:
                # Update status based on Twilio status
                status_mapping = {
                    "completed": CallStatus.COMPLETED,
                    "no-answer": CallStatus.NO_ANSWER,
                    "busy": CallStatus.NO_ANSWER,
                    "failed": CallStatus.FAILED,
                    "canceled": CallStatus.FAILED,
                }

                if call_status.lower() in status_mapping:
                    call_attempt.status = status_mapping[call_status.lower()]
                    call_attempt.save()

            # Twilio expects TwiML or empty response
            return HttpResponse("", content_type="text/xml")

        except Exception as e:
            logger.error(f"Error processing Twilio webhook: {e}", exc_info=True)
            return HttpResponse("", content_type="text/xml")


@method_decorator(csrf_exempt, name="dispatch")
class GoogleCalendarWebhookView(View):
    """
    Webhook endpoint for Google Calendar push notifications.

    Google Calendar sends notifications when events are created, updated, or deleted.
    Expected format:
    {
        "header": {
            "X-Goog-Channel-ID": "channel_id",
            "X-Goog-Resource-ID": "resource_id",
            "X-Goog-Channel-Token": "token",
            "X-Goog-Resource-State": "sync" | "exists" | "not_exists",
            "X-Goog-Resource-URI": "calendar URI",
            "X-Goog-Message-Number": "message_number"
        }
    }
    """

    def post(self, request):
        """Handle Google Calendar push notification."""
        try:
            from django.utils.crypto import constant_time_compare

            # Extract headers
            channel_id = request.headers.get("X-Goog-Channel-ID")
            resource_id = request.headers.get("X-Goog-Resource-ID", "")
            resource_state = request.headers.get("X-Goog-Resource-State")
            channel_token = request.headers.get("X-Goog-Channel-Token", "")

            logger.info(
                f"Google Calendar webhook received: channel_id={channel_id}, state={resource_state}"
            )

            # ── Authenticate against stored watch state (CWE-345 fix) ──
            # Resolve the watch ONLY by channel_id, then require an exact match on
            # the stored random token and resource_id. The target user is taken
            # from the watch row — never derived from an attacker-supplied header.
            # This runs before ANY action (including delete), so a forged request
            # can neither trigger a sync nor delete a watch.
            watch = None
            if channel_id:
                watch = (
                    GoogleCalendarWatch.objects.select_related("user")
                    .filter(channel_id=channel_id)
                    .first()
                )
            if not watch:
                logger.warning(f"Rejected Google Calendar webhook: unknown channel_id={channel_id}")
                return JsonResponse({"error": "Unknown channel"}, status=403)
            if not (
                watch.token and channel_token and constant_time_compare(channel_token, watch.token)
            ):
                logger.warning(
                    f"Rejected Google Calendar webhook: token mismatch on channel_id={channel_id}"
                )
                return JsonResponse({"error": "Invalid token"}, status=403)
            if (
                resource_id
                and watch.resource_id
                and not constant_time_compare(resource_id, watch.resource_id)
            ):
                # constant_time_compare avoids leaking the watch's resource_id
                # one byte at a time through a timing side channel — same
                # defense the channel-token check above already uses.
                logger.warning(
                    f"Rejected Google Calendar webhook: resource_id mismatch on "
                    f"channel_id={channel_id}"
                )
                return JsonResponse({"error": "Resource mismatch"}, status=403)

            user_id = watch.user_id

            # Handle expiration notification (now authenticated)
            if resource_state == "not_exists":
                logger.info(f"Watch channel {channel_id} expired for user {watch.user.username}")
                watch.delete()
                log_activity(
                    user=watch.user,
                    action="Google Calendar watch channel expired",
                    details={"channel_id": channel_id},
                )
                return JsonResponse({"status": "acknowledged"}, status=200)

            # Handle sync / event-change notifications
            if resource_state in ("sync", "exists"):
                logger.info(f"Google Calendar {resource_state} notification for user {user_id}")
                result = handle_google_calendar_notification(user_id)
                if result.get("success"):
                    logger.info(f"Calendar sync completed: {result}")
                else:
                    logger.error(f"Calendar sync failed: {result.get('error')}")

            # Always return 200 to acknowledge receipt
            return JsonResponse({"status": "success"}, status=200)

        except Exception as e:
            logger.error(f"Error processing Google Calendar webhook: {e}", exc_info=True)
            # Still return 200 to prevent Google from retrying
            return JsonResponse({"status": "error", "message": str(e)}, status=200)
