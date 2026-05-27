"""
Webhook views for external integrations (ElevenLabs, Twilio).
"""
import json
import logging
from django.http import JsonResponse, HttpResponse
from django.views.decorators.csrf import csrf_exempt
from django.utils.decorators import method_decorator
from django.views import View

from .models import CallAttempt, Meeting, GoogleCalendarWatch
from .constants import CallStatus, CallPhase, LogLevel
from .selectors import get_call_attempt_by_external_id
from .services import log_activity, handle_google_calendar_notification

logger = logging.getLogger(__name__)


@method_decorator(csrf_exempt, name='dispatch')
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
        try:
            # Parse webhook payload
            if request.content_type == 'application/json':
                payload = json.loads(request.body)
            else:
                payload = request.POST.dict()
            
            logger.info("ElevenLabs webhook received")
            
            # ElevenLabs webhook structure:
            # - Top level has "type" and "data"
            # - "data" contains conversation_id, status, transcript, metadata
            webhook_type = payload.get('type', '')
            data = payload.get('data', {})
            
            # Extract call information from data object
            # Try multiple possible fields for call_id
            call_id = (
                data.get('conversation_id') or 
                data.get('call_id') or 
                payload.get('call_id') or 
                payload.get('id') or
                data.get('id')
            )
            
            # Extract status from data object
            status = data.get('status', '').upper() or payload.get('status', '').upper()
            
            # Extract transcript - ElevenLabs sends it in a structured format
            transcript_data = data.get('transcript', {})
            
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
                transcript_text = payload.get('transcript') or payload.get('conversation_transcript')
            
            if not transcript_text:
                logger.warning(f"No transcript found in webhook for call_id: {call_id}")
            
            # Extract summary from analysis data
            analysis = data.get('analysis', {})
            summary = None
            summary_title = None
            if isinstance(analysis, dict):
                summary = analysis.get('transcript_summary') or analysis.get('summary')
                summary_title = analysis.get('call_summary_title')
            
            # Extract recording URL from metadata
            metadata = data.get('metadata', {}) or payload.get('metadata', {})
            recording_url = (
                metadata.get('recording_url') or 
                metadata.get('audio_url') or 
                data.get('recording_url') or 
                payload.get('recording_url') or 
                payload.get('audio_url')
            )
            
            if not call_id:
                logger.warning("ElevenLabs webhook missing conversation_id/call_id")
                # Still return 200 to prevent retries
                return JsonResponse({'status': 'received', 'error': 'Missing conversation_id'}, status=200)
            
            # Find the call attempt
            call_attempt = get_call_attempt_by_external_id(call_id)
            
            if not call_attempt:
                # Try to find by metadata if call_id doesn't match
                if metadata and 'call_attempt_id' in metadata:
                    try:
                        call_attempt = CallAttempt.objects.get(id=metadata['call_attempt_id'])
                    except CallAttempt.DoesNotExist:
                        pass
                
                if not call_attempt:
                    logger.warning(f"Call attempt not found for conversation_id: {call_id}")
                    # Still return 200 to prevent retries
                    return JsonResponse({'status': 'received', 'message': 'Call attempt not found'}, status=200)
            
            # Update call attempt with webhook data
            if transcript_text:
                call_attempt.transcript = transcript_text
                logger.info(f"Saved transcript for call {call_attempt.id} ({len(transcript_text)} chars)")
            
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
                'DONE': CallStatus.COMPLETED,
                'COMPLETED': CallStatus.COMPLETED,
                'ANSWERED': CallStatus.COMPLETED,
                'NO_ANSWER': CallStatus.NO_ANSWER,
                'BUSY': CallStatus.NO_ANSWER,
                'FAILED': CallStatus.FAILED,
                'CANCELLED': CallStatus.FAILED,
                'CANCELED': CallStatus.FAILED,
            }
            
            if status in status_mapping:
                call_attempt.status = status_mapping[status]
            elif status == 'IN_PROGRESS' or status == 'RINGING' or status == 'IN_PROGRESS':
                call_attempt.status = CallStatus.IN_PROGRESS
            else:
                # Default to completed if transcript exists or status is "done"
                if transcript_text or status.lower() == 'done':
                    call_attempt.status = CallStatus.COMPLETED
                else:
                    call_attempt.status = CallStatus.FAILED
            
            call_attempt.save()

            # Synchronous Claude analysis on post-call transcripts.
            # Failures are logged but do not break the webhook response.
            if (call_attempt.phase == CallPhase.POST_MEETING
                    and call_attempt.transcript
                    and call_attempt.transcript.strip()):
                try:
                    from voice.services.llm import analyze_post_call
                    visit = call_attempt.visit
                    post_prompt = visit.post_call_prompt if visit else ''
                    visit_ctx_parts = []
                    if visit:
                        if visit.client:
                            visit_ctx_parts.append(f"Client: {visit.client.name} ({visit.client.industry or 'industry unknown'})")
                        if visit.agent:
                            agent_name = visit.agent.get_full_name() or visit.agent.username
                            visit_ctx_parts.append(f"Agent: {agent_name}")
                        if visit.methodology:
                            visit_ctx_parts.append(f"Methodology: {visit.methodology.name}")
                        if visit.title:
                            visit_ctx_parts.append(f"Meeting: {visit.title}")
                    visit_context = " | ".join(visit_ctx_parts)
                    analysis = analyze_post_call(
                        transcript=call_attempt.transcript,
                        post_call_prompt=post_prompt or '',
                        visit_context=visit_context,
                    )
                    if analysis:
                        call_attempt.analysis = analysis
                        call_attempt.save(update_fields=['analysis'])
                        logger.info(f"Claude analysis saved for CallAttempt #{call_attempt.id}")
                    else:
                        logger.warning(f"Claude analysis returned None for CallAttempt #{call_attempt.id}")
                except Exception as e:
                    logger.error(f"Claude analysis failed for CallAttempt #{call_attempt.id}: {e}", exc_info=True)

            # Update meeting completion status if call was successful
            if call_attempt.status == CallStatus.COMPLETED:
                meeting = call_attempt.meeting
                if meeting:
                    if call_attempt.phase == CallPhase.PRE_MEETING:
                        meeting.is_pre_call_completed = True
                    elif call_attempt.phase == CallPhase.POST_MEETING:
                        meeting.is_post_call_completed = True
                    meeting.save()

                    # Log successful call completion
                    log_activity(
                        meeting=meeting,
                        user=meeting.agent,
                        action=f"{call_attempt.get_phase_display()} call completed",
                        details={
                            'call_id': call_id,
                            'has_transcript': bool(transcript_text),
                            'has_recording': bool(recording_url),
                            'webhook_type': webhook_type,
                            'transcript_length': len(transcript_text) if transcript_text else 0
                        }
                    )

                    # Trigger Pipedrive sync if post-meeting call
                    if call_attempt.phase == CallPhase.POST_MEETING:
                        try:
                            from .services import sync_note_to_pipedrive
                            # Use summary if available, fallback to transcript
                            note_text = call_attempt.summary if call_attempt.summary else transcript_text
                            if note_text:
                                sync_note_to_pipedrive(
                                    deal_id=None,  # Will be determined from meeting (now uses domain-based search)
                                    text=note_text,
                                    meeting=meeting
                                )
                        except Exception as e:
                            logger.error(f"Failed to sync to Pipedrive: {e}", exc_info=True)
                            log_activity(
                                meeting=meeting,
                                action="Pipedrive sync failed after call completion",
                                details={'error': str(e)},
                                level=LogLevel.ERROR
                            )
                # If meeting is None, this is a visit-linked call (new flow).
                # Transcript/summary/recording_url are already saved on call_attempt above.
            else:
                # Handle pre-meeting call failure: create -30 call if -60 failed.
                # This only applies to meeting-linked calls; skip for visit-linked.
                if (call_attempt.meeting and
                    call_attempt.phase == CallPhase.PRE_MEETING and
                    call_attempt.status in [CallStatus.NO_ANSWER, CallStatus.FAILED] and
                    call_attempt.scheduled_offset_minutes == -60):  # -60 minutes
                    # Check if -30 call doesn't exist yet
                    from django.utils import timezone
                    from datetime import timedelta
                    from .constants import PRE_MEETING_OFFSETS

                    existing_30 = CallAttempt.objects.filter(
                        meeting=call_attempt.meeting,
                        phase=CallPhase.PRE_MEETING,
                        scheduled_offset_minutes=PRE_MEETING_OFFSETS[1]  # -30 minutes
                    ).exists()

                    if not existing_30 and call_attempt.meeting.start_time > timezone.now():
                        # Create -30 minute call attempt
                        scheduled_time = call_attempt.meeting.start_time + timedelta(minutes=PRE_MEETING_OFFSETS[1])
                        CallAttempt.objects.create(
                            meeting=call_attempt.meeting,
                            phase=CallPhase.PRE_MEETING,
                            scheduled_offset_minutes=PRE_MEETING_OFFSETS[1],
                            scheduled_time=scheduled_time,
                            status=CallStatus.SCHEDULED
                        )
                        log_activity(
                            meeting=call_attempt.meeting,
                            user=call_attempt.meeting.agent,
                            action="Created -30 minute retry call after -60 call failed",
                            details={'failed_call_id': call_attempt.id, 'failed_status': call_attempt.status}
                        )

                # Log non-completed status — guard against missing meeting
                if call_attempt.meeting:
                    log_activity(
                        meeting=call_attempt.meeting,
                        user=call_attempt.meeting.agent,
                        action=f"{call_attempt.get_phase_display()} call {call_attempt.get_status_display()}",
                        details={
                            'call_id': call_id,
                            'status': status,
                            'webhook_type': webhook_type
                        },
                        level=LogLevel.WARNING if call_attempt.status == CallStatus.NO_ANSWER else LogLevel.ERROR
                    )
            
            return JsonResponse({'status': 'success', 'call_attempt_id': call_attempt.id})
            
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in ElevenLabs webhook: {e}")
            return JsonResponse({'error': 'Invalid JSON'}, status=400)
        except Exception as e:
            logger.error(f"Error processing ElevenLabs webhook: {e}", exc_info=True)
            return JsonResponse({'error': 'Internal server error'}, status=500)
    
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
        turns = transcript_data.get('turns', [])
        
        if turns:
            # Build readable transcript from turns
            transcript_lines = []
            for turn in turns:
                if not isinstance(turn, dict):
                    continue
                
                role = turn.get('role', 'unknown')
                content = turn.get('content', '') or turn.get('text', '') or turn.get('message', '')
                
                if content:
                    role_label = 'Agent' if role == 'agent' else 'User' if role == 'user' else role.title()
                    transcript_lines.append(f"{role_label}: {content}")
            
            return "\n\n".join(transcript_lines) if transcript_lines else ""
        
        # Structure 2: Direct text fields
        text_fields = ['text', 'content', 'transcript', 'message', 'summary']
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
        analysis = transcript_data.get('analysis', {})
        if isinstance(analysis, dict):
            summary = analysis.get('summary') or analysis.get('transcript')
            if summary:
                return str(summary)
        
        # Structure 4: Last resort - stringify the whole thing
        logger.warning(f"Could not extract transcript from dict structure. Available keys: {list(transcript_data.keys())}")
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
            
            role = turn.get('role', 'unknown')
            # Try multiple possible message fields
            message = (
                turn.get('message') or 
                turn.get('content') or 
                turn.get('text')
            )
            
            if message:
                role_label = 'Agent' if role == 'agent' else 'User' if role == 'user' else role.title()
                transcript_lines.append(f"{role_label}: {message}")
        
        return "\n\n".join(transcript_lines) if transcript_lines else ""
    
    def get(self, request):
        """Handle GET request for webhook verification (if required)."""
        return JsonResponse({'status': 'ok', 'message': 'ElevenLabs webhook endpoint is active'})


@method_decorator(csrf_exempt, name='dispatch')
class TwilioWebhookView(View):
    """
    Optional webhook endpoint for Twilio call status updates.
    
    Note: ElevenLabs webhook is the primary source of call status.
    This endpoint is kept for additional tracking/debugging purposes.
    Twilio number should be configured in ElevenLabs dashboard.
    """
    
    def post(self, request):
        """Handle Twilio webhook POST request."""
        try:
            # Twilio sends form data, not JSON
            call_sid = request.POST.get('CallSid')
            call_status = request.POST.get('CallStatus')
            
            logger.info(f"Twilio webhook received: CallSid={call_sid}, Status={call_status}")
            
            if not call_sid:
                return JsonResponse({'error': 'Missing CallSid'}, status=400)
            
            # Find call attempt by Twilio SID
            call_attempt = get_call_attempt_by_external_id(call_sid)
            
            if call_attempt:
                # Update status based on Twilio status
                status_mapping = {
                    'completed': CallStatus.COMPLETED,
                    'no-answer': CallStatus.NO_ANSWER,
                    'busy': CallStatus.NO_ANSWER,
                    'failed': CallStatus.FAILED,
                    'canceled': CallStatus.FAILED,
                }
                
                if call_status.lower() in status_mapping:
                    call_attempt.status = status_mapping[call_status.lower()]
                    call_attempt.save()
            
            # Twilio expects TwiML or empty response
            return HttpResponse('', content_type='text/xml')
            
        except Exception as e:
            logger.error(f"Error processing Twilio webhook: {e}", exc_info=True)
            return HttpResponse('', content_type='text/xml')


@method_decorator(csrf_exempt, name='dispatch')
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
            # Extract headers
            channel_id = request.headers.get('X-Goog-Channel-ID')
            resource_id = request.headers.get('X-Goog-Resource-ID')
            resource_state = request.headers.get('X-Goog-Resource-State')
            channel_token = request.headers.get('X-Goog-Channel-Token', '')
            
            logger.info(f"Google Calendar webhook received: channel_id={channel_id}, state={resource_state}")
            
            # Handle expiration notification
            if resource_state == 'not_exists':
                # Channel expired or was stopped
                if channel_id:
                    watch = GoogleCalendarWatch.objects.filter(channel_id=channel_id).first()
                    if watch:
                        logger.info(f"Watch channel {channel_id} expired for user {watch.user.username}")
                        watch.delete()
                        log_activity(
                            user=watch.user,
                            action="Google Calendar watch channel expired",
                            details={'channel_id': channel_id}
                        )
                return JsonResponse({'status': 'acknowledged'}, status=200)
            
            # Extract user ID from channel token (format: "user_{user_id}_{channel_id}")
            user_id = None
            if channel_token.startswith('user_'):
                try:
                    parts = channel_token.split('_')
                    if len(parts) >= 2:
                        user_id = int(parts[1])
                except (ValueError, IndexError):
                    pass
            
            # Find watch channel to get user
            if not user_id and channel_id:
                watch = GoogleCalendarWatch.objects.filter(channel_id=channel_id).first()
                if watch:
                    user_id = watch.user.id
            
            if not user_id:
                logger.warning(f"Could not determine user from Google Calendar webhook: channel_id={channel_id}, token={channel_token}")
                return JsonResponse({'status': 'received', 'message': 'User not found'}, status=200)
            
            # Handle sync notification
            if resource_state == 'sync':
                # Initial sync - full calendar sync
                logger.info(f"Google Calendar sync notification for user {user_id}")
                result = handle_google_calendar_notification(user_id)
                if result.get('success'):
                    logger.info(f"Calendar sync completed: {result}")
                else:
                    logger.error(f"Calendar sync failed: {result.get('error')}")
            
            elif resource_state == 'exists':
                # Event was created or updated - sync calendar
                logger.info(f"Google Calendar event change notification for user {user_id}")
                result = handle_google_calendar_notification(user_id)
                if result.get('success'):
                    logger.info(f"Calendar sync completed: {result}")
                else:
                    logger.error(f"Calendar sync failed: {result.get('error')}")
            
            # Always return 200 to acknowledge receipt
            return JsonResponse({'status': 'success'}, status=200)
            
        except Exception as e:
            logger.error(f"Error processing Google Calendar webhook: {e}", exc_info=True)
            # Still return 200 to prevent Google from retrying
            return JsonResponse({'status': 'error', 'message': str(e)}, status=200)

