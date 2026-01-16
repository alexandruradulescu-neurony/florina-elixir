"""
Scheduled tasks for the voice app using APScheduler.
These functions are registered with APScheduler in voice/apps.py.
"""
from django.utils import timezone
from datetime import timedelta
import logging
from threading import Thread

from .models import Meeting, User, CallAttempt
from .constants import CallPhase, CallStatus, LogLevel
from .services import (
    check_pre_meeting_calls,
    check_post_meeting_calls,
    trigger_agent_call,
    format_prompt_with_context,
    format_first_message_with_context,
    sync_google_calendar,
    log_activity,
    sync_call_status_from_api
)
from .selectors import get_active_prompt, get_sales_agents
from .utils import calculate_call_time

logger = logging.getLogger(__name__)


def check_and_trigger_calls():
    """
    Main periodic task that checks for meetings needing calls and triggers them.
    Uses hybrid approach:
    1. Primary: Check for pre-programmed CallAttempts ready to execute
    2. Backup: Window-based check for any missed calls
    
    Runs every 5 minutes via APScheduler.
    """
    from django.utils import timezone
    from .models import CallAttempt
    from .constants import CallStatus
    
    logger.info("Starting call check task")
    
    try:
        now = timezone.now()
        triggered_count = 0
        
        # PRIMARY: Check for pre-programmed CallAttempts ready to execute
        # Look for scheduled calls where scheduled_time <= now
        ready_calls = CallAttempt.objects.filter(
            status=CallStatus.SCHEDULED,
            scheduled_time__lte=now
        ).select_related('meeting', 'meeting__agent')
        
        logger.info(f"Found {ready_calls.count()} pre-programmed calls ready to execute")
        
        for call_attempt in ready_calls:
            # Validate timing constraints
            if call_attempt.phase == 'PRE':
                # Pre-meeting: execute if meeting hasn't started or just started (within 5 minutes)
                # This handles cases where meeting was created late
                time_since_meeting_start = now - call_attempt.meeting.start_time
                # Meeting hasn't started yet OR meeting just started (within 5 minutes grace period)
                can_execute = (call_attempt.meeting.start_time > now) or (
                    call_attempt.meeting.start_time <= now and 
                    0 <= time_since_meeting_start.total_seconds() <= 300
                )
                
                logger.info(f"Pre-meeting call {call_attempt.id} for meeting '{call_attempt.meeting.title}': "
                           f"meeting_start={call_attempt.meeting.start_time}, now={now}, "
                           f"can_execute={can_execute}")
                
                if can_execute:
                    # Execute the call using existing CallAttempt
                    logger.info(f"Triggering pre-meeting call {call_attempt.id}")
                    thread = Thread(
                        target=execute_scheduled_call,
                        args=(call_attempt.id,)
                    )
                    thread.daemon = True
                    thread.start()
                    triggered_count += 1
            else:  # POST
                # Post-meeting: only execute if meeting has ended
                can_execute = call_attempt.meeting.end_time < now
                
                logger.info(f"Post-meeting call {call_attempt.id} for meeting '{call_attempt.meeting.title}': "
                           f"meeting_end={call_attempt.meeting.end_time}, now={now}, "
                           f"can_execute={can_execute}")
                
                if can_execute:
                    # Execute the call using existing CallAttempt
                    logger.info(f"Triggering post-meeting call {call_attempt.id}")
                    thread = Thread(
                        target=execute_scheduled_call,
                        args=(call_attempt.id,)
                    )
                    thread.daemon = True
                    thread.start()
                    triggered_count += 1
        
        # RETRY LOGIC: Check for failed calls that need retries
        # Pre-meeting: retry failed calls every 5 minutes until meeting starts
        failed_pre_calls = CallAttempt.objects.filter(
            meeting__start_time__gt=now,  # Meeting hasn't started
            phase='PRE',
            status__in=[CallStatus.NO_ANSWER, CallStatus.FAILED],
            meeting__agent__is_sales_agent=True
        ).select_related('meeting', 'meeting__agent')
        
        for call_attempt in failed_pre_calls:
            # Check if it's been at least 5 minutes since last attempt
            # Use updated_at as proxy for last retry time
            time_since_last_attempt = now - call_attempt.updated_at
            if time_since_last_attempt.total_seconds() >= 300:  # 5 minutes
                # Check if meeting already has a completed pre-call
                if not call_attempt.meeting.is_pre_call_completed:
                    # Retry the call
                    thread = Thread(
                        target=retry_failed_call,
                        args=(call_attempt.id,)
                    )
                    thread.daemon = True
                    thread.start()
                    triggered_count += 1
        
        # Post-meeting: retry failed calls every 5 minutes after meeting ends
        failed_post_calls = CallAttempt.objects.filter(
            meeting__end_time__lt=now,  # Meeting has ended
            phase='POST',
            status__in=[CallStatus.NO_ANSWER, CallStatus.FAILED],
            meeting__agent__is_sales_agent=True
        ).select_related('meeting', 'meeting__agent')
        
        for call_attempt in failed_post_calls:
            # Check if it's been at least 5 minutes since last attempt
            time_since_last_attempt = now - call_attempt.updated_at
            if time_since_last_attempt.total_seconds() >= 300:  # 5 minutes
                # Check if meeting already has a completed post-call
                if not call_attempt.meeting.is_post_call_completed:
                    # Retry the call
                    thread = Thread(
                        target=retry_failed_call,
                        args=(call_attempt.id,)
                    )
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
                phase='PRE',
                scheduled_offset_minutes=offset,
                status=CallStatus.SCHEDULED
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
                phase='POST',
                scheduled_offset_minutes=offset,
                status=CallStatus.SCHEDULED
            ).exists()
            
            if not existing:
                # Only trigger if no scheduled CallAttempt exists
                thread = Thread(target=trigger_post_meeting_call, args=(meeting.id, offset))
                thread.daemon = True
                thread.start()
                triggered_count += 1
        
        logger.info(f"Call check completed: {triggered_count} calls triggered ({len(ready_calls)} from pre-programmed, {len(pre_meeting_calls)} pre + {len(post_meeting_calls)} post from backup)")
        
        return {
            'triggered': triggered_count,
            'pre_programmed': len(ready_calls),
            'backup_pre': len(pre_meeting_calls),
            'backup_post': len(post_meeting_calls)
        }
        
    except Exception as e:
        logger.error(f"Error in check_and_trigger_calls: {e}", exc_info=True)
        log_activity(
            action="Call check task failed",
            details={'error': str(e)},
            level=LogLevel.ERROR
        )
        raise


def execute_scheduled_call(call_attempt_id: int):
    """
    Execute a pre-programmed CallAttempt that's ready to run.
    Uses the existing CallAttempt record instead of creating a new one.
    """
    from .models import CallAttempt
    from .constants import CallPhase
    
    try:
        call_attempt = CallAttempt.objects.get(id=call_attempt_id)
        meeting = call_attempt.meeting
        agent = meeting.agent
        
        # Validate agent has phone number
        if not agent.phone_number:
            logger.warning(f"Agent {agent.username} has no phone number for call {call_attempt_id}")
            call_attempt.status = CallStatus.FAILED
            call_attempt.save()
            return {'success': False, 'error': 'No phone number'}
        
        # Get active prompt
        prompt = get_active_prompt(call_attempt.phase)
        if not prompt:
            logger.error(f"No active prompt found for phase {call_attempt.phase}")
            call_attempt.status = CallStatus.FAILED
            call_attempt.save()
            return {'success': False, 'error': 'No active prompt'}
        
        # Format prompt with meeting context
        formatted_prompt = format_prompt_with_context(prompt.system_prompt, meeting)
        formatted_first_message = None
        if prompt.first_message:
            formatted_first_message = format_first_message_with_context(prompt.first_message, meeting)
        
        # Prepare context data
        context_data = {
            'meeting_id': meeting.id,
            'offset_minutes': call_attempt.scheduled_offset_minutes,
            'call_attempt_id': call_attempt.id,
        }
        
        # Trigger the call using existing CallAttempt
        result = trigger_agent_call(
            agent_phone=agent.phone_number,
            prompt_text=formatted_prompt,
            context_data=context_data,
            call_attempt=call_attempt,
            first_message_text=formatted_first_message
        )
        
        if result['success']:
            logger.info(f"Scheduled call {call_attempt_id} executed successfully")
        else:
            logger.error(f"Failed to execute scheduled call {call_attempt_id}: {result.get('error')}")
        
        return result
        
    except CallAttempt.DoesNotExist:
        logger.error(f"CallAttempt {call_attempt_id} not found")
        return {'success': False, 'error': 'CallAttempt not found'}
    except Exception as e:
        logger.error(f"Error executing scheduled call {call_attempt_id}: {e}", exc_info=True)
        log_activity(
            action="Scheduled call execution failed",
            details={'call_attempt_id': call_attempt_id, 'error': str(e)},
            level=LogLevel.ERROR
        )
        raise


def retry_failed_call(call_attempt_id: int):
    """
    Retry a failed call attempt (NO_ANSWER or FAILED).
    Updates the existing CallAttempt and triggers a new call.
    """
    from .models import CallAttempt
    from .constants import CallPhase, CallStatus
    
    try:
        call_attempt = CallAttempt.objects.get(id=call_attempt_id)
        meeting = call_attempt.meeting
        agent = meeting.agent
        
        # Validate agent has phone number
        if not agent.phone_number:
            logger.warning(f"Agent {agent.username} has no phone number for retry {call_attempt_id}")
            return {'success': False, 'error': 'No phone number'}
        
        # Get active prompt
        prompt = get_active_prompt(call_attempt.phase)
        if not prompt:
            logger.error(f"No active prompt found for phase {call_attempt.phase}")
            return {'success': False, 'error': 'No active prompt'}
        
        # Reset call attempt status to SCHEDULED for retry
        call_attempt.status = CallStatus.SCHEDULED
        call_attempt.external_call_id = None  # Clear old call ID
        call_attempt.save()
        
        # Format prompt with meeting context
        formatted_prompt = format_prompt_with_context(prompt.system_prompt, meeting)
        formatted_first_message = None
        if prompt.first_message:
            formatted_first_message = format_first_message_with_context(prompt.first_message, meeting)
        
        # Prepare context data
        context_data = {
            'meeting_id': meeting.id,
            'offset_minutes': call_attempt.scheduled_offset_minutes,
            'call_attempt_id': call_attempt.id,
            'is_retry': True,
        }
        
        # Trigger the call using existing CallAttempt
        result = trigger_agent_call(
            agent_phone=agent.phone_number,
            prompt_text=formatted_prompt,
            context_data=context_data,
            call_attempt=call_attempt,
            first_message_text=formatted_first_message
        )
        
        if result['success']:
            logger.info(f"Retry call {call_attempt_id} executed successfully")
            log_activity(
                meeting=meeting,
                user=agent,
                action=f"Retry call triggered for {call_attempt.get_phase_display()}",
                details={'call_attempt_id': call_attempt_id, 'offset': call_attempt.scheduled_offset_minutes}
            )
        else:
            logger.error(f"Failed to retry call {call_attempt_id}: {result.get('error')}")
        
        return result
        
    except CallAttempt.DoesNotExist:
        logger.error(f"CallAttempt {call_attempt_id} not found for retry")
        return {'success': False, 'error': 'CallAttempt not found'}
    except Exception as e:
        logger.error(f"Error retrying call {call_attempt_id}: {e}", exc_info=True)
        log_activity(
            action="Call retry failed",
            details={'call_attempt_id': call_attempt_id, 'error': str(e)},
            level=LogLevel.ERROR
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
        meeting = Meeting.objects.get(id=meeting_id)
        agent = meeting.agent
        
        # Validate agent has phone number
        if not agent.phone_number:
            logger.warning(f"Agent {agent.username} has no phone number for meeting {meeting_id}")
            log_activity(
                meeting=meeting,
                user=agent,
                action="Pre-meeting call skipped - no phone number",
                level=LogLevel.WARNING
            )
            return {'success': False, 'error': 'No phone number'}
        
        # Get active prompt for pre-meeting
        prompt = get_active_prompt(CallPhase.PRE_MEETING)
        if not prompt:
            logger.error(f"No active pre-meeting prompt found")
            log_activity(
                meeting=meeting,
                user=agent,
                action="Pre-meeting call failed - no active prompt",
                level=LogLevel.ERROR
            )
            return {'success': False, 'error': 'No active prompt'}
        
        # Validate prompt has content
        if not prompt.system_prompt or not prompt.system_prompt.strip():
            logger.error(f"Active pre-meeting prompt exists but has no system_prompt content")
            log_activity(
                meeting=meeting,
                user=agent,
                action="Pre-meeting call failed - prompt has no content",
                level=LogLevel.ERROR
            )
            return {'success': False, 'error': 'Prompt has no content'}
        
        # Check if CallAttempt already exists (from pre-programming)
        call_attempt = CallAttempt.objects.filter(
            meeting=meeting,
            phase=CallPhase.PRE_MEETING,
            scheduled_offset_minutes=offset_minutes,
            status=CallStatus.SCHEDULED
        ).first()
        
        if not call_attempt:
            # Create new call attempt record if it doesn't exist
            scheduled_time = meeting.start_time + timedelta(minutes=offset_minutes)
            call_attempt = CallAttempt.objects.create(
                meeting=meeting,
                phase=CallPhase.PRE_MEETING,
                scheduled_offset_minutes=offset_minutes,
                scheduled_time=scheduled_time,
                status=CallStatus.SCHEDULED
            )
        
        # Format prompt with meeting context
        formatted_prompt = format_prompt_with_context(prompt.system_prompt, meeting)
        
        # Format first_message if available
        formatted_first_message = None
        if prompt.first_message:
            formatted_first_message = format_first_message_with_context(prompt.first_message, meeting)
        
        # Prepare context data
        context_data = {
            'meeting_id': meeting.id,
            'offset_minutes': offset_minutes,
            'call_attempt_id': call_attempt.id,
        }
        
        # Trigger the call
        result = trigger_agent_call(
            agent_phone=agent.phone_number,
            prompt_text=formatted_prompt,
            context_data=context_data,
            call_attempt=call_attempt,
            first_message_text=formatted_first_message
        )
        
        if result['success']:
            logger.info(f"Pre-meeting call triggered for meeting {meeting_id} at offset {offset_minutes}")
        else:
            logger.error(f"Failed to trigger pre-meeting call: {result.get('error')}")
        
        return result
        
    except Meeting.DoesNotExist:
        logger.error(f"Meeting {meeting_id} not found")
        return {'success': False, 'error': 'Meeting not found'}
    except Exception as e:
        logger.error(f"Error triggering pre-meeting call: {e}", exc_info=True)
        log_activity(
            action="Pre-meeting call trigger failed",
            details={'meeting_id': meeting_id, 'error': str(e)},
            level=LogLevel.ERROR
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
        meeting = Meeting.objects.get(id=meeting_id)
        agent = meeting.agent
        
        # Validate agent has phone number
        if not agent.phone_number:
            logger.warning(f"Agent {agent.username} has no phone number for meeting {meeting_id}")
            log_activity(
                meeting=meeting,
                user=agent,
                action="Post-meeting call skipped - no phone number",
                level=LogLevel.WARNING
            )
            return {'success': False, 'error': 'No phone number'}
        
        # Get active prompt for post-meeting
        prompt = get_active_prompt(CallPhase.POST_MEETING)
        if not prompt:
            logger.error(f"No active post-meeting prompt found")
            log_activity(
                meeting=meeting,
                user=agent,
                action="Post-meeting call failed - no active prompt",
                level=LogLevel.ERROR
            )
            return {'success': False, 'error': 'No active prompt'}
        
        # Validate prompt has content
        if not prompt.system_prompt or not prompt.system_prompt.strip():
            logger.error(f"Active post-meeting prompt exists but has no system_prompt content")
            log_activity(
                meeting=meeting,
                user=agent,
                action="Post-meeting call failed - prompt has no content",
                level=LogLevel.ERROR
            )
            return {'success': False, 'error': 'Prompt has no content'}
        
        # Check if CallAttempt already exists (from pre-programming)
        call_attempt = CallAttempt.objects.filter(
            meeting=meeting,
            phase=CallPhase.POST_MEETING,
            scheduled_offset_minutes=offset_minutes,
            status=CallStatus.SCHEDULED
        ).first()
        
        if not call_attempt:
            # Create new call attempt record if it doesn't exist
            scheduled_time = meeting.end_time + timedelta(minutes=offset_minutes)
            call_attempt = CallAttempt.objects.create(
                meeting=meeting,
                phase=CallPhase.POST_MEETING,
                scheduled_offset_minutes=offset_minutes,
                scheduled_time=scheduled_time,
                status=CallStatus.SCHEDULED
            )
        
        # Format prompt with meeting context
        formatted_prompt = format_prompt_with_context(prompt.system_prompt, meeting)
        
        # Format first_message if available
        formatted_first_message = None
        if prompt.first_message:
            formatted_first_message = format_first_message_with_context(prompt.first_message, meeting)
        
        # Prepare context data
        context_data = {
            'meeting_id': meeting.id,
            'offset_minutes': offset_minutes,
            'call_attempt_id': call_attempt.id,
        }
        
        # Trigger the call
        result = trigger_agent_call(
            agent_phone=agent.phone_number,
            prompt_text=formatted_prompt,
            context_data=context_data,
            call_attempt=call_attempt,
            first_message_text=formatted_first_message
        )
        
        if result['success']:
            logger.info(f"Post-meeting call triggered for meeting {meeting_id} at offset {offset_minutes}")
        else:
            logger.error(f"Failed to trigger post-meeting call: {result.get('error')}")
        
        return result
        
    except Meeting.DoesNotExist:
        logger.error(f"Meeting {meeting_id} not found")
        return {'success': False, 'error': 'Meeting not found'}
    except Exception as e:
        logger.error(f"Error triggering post-meeting call: {e}", exc_info=True)
        log_activity(
            action="Post-meeting call trigger failed",
            details={'meeting_id': meeting_id, 'error': str(e)},
            level=LogLevel.ERROR
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
            return {'success': False, 'error': 'Not a sales agent'}
        
        # Sync calendar (session will be None for background tasks - needs to be handled differently)
        # For now, we'll log that sync needs to be done manually or via OAuth
        logger.info(f"Calendar sync requested for user {user_id}")
        
        # Note: Calendar sync requires user's OAuth session, which may not be available in background tasks
        # This task should be called from a view where session is available, or we need to store credentials
        log_activity(
            user=user,
            action="Calendar sync task triggered",
            details={'user_id': user_id}
        )
        
        return {'success': True, 'message': 'Sync task triggered'}
        
    except User.DoesNotExist:
        logger.error(f"User {user_id} not found")
        return {'success': False, 'error': 'User not found'}
    except Exception as e:
        logger.error(f"Error syncing calendar for user {user_id}: {e}", exc_info=True)
        log_activity(
            action="Calendar sync task failed",
            details={'user_id': user_id, 'error': str(e)},
            level=LogLevel.ERROR
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
        from .services import sync_google_calendar
        from datetime import datetime, time
        
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
                    session=None  # Background task - no session
                )
                
                if results.get('errors'):
                    errors.extend([f"{agent.username}: {err}" for err in results['errors']])
                
                synced_count += 1
                
                log_activity(
                    user=agent,
                    action="Calendar sync completed",
                    details=results
                )
                
            except Exception as e:
                error_msg = f"Error syncing calendar for {agent.username}: {str(e)}"
                logger.error(error_msg, exc_info=True)
                errors.append(error_msg)
                log_activity(
                    user=agent,
                    action="Calendar sync failed",
                    details={'error': str(e)},
                    level=LogLevel.ERROR
                )
        
        logger.info(f"Calendar sync completed: {synced_count} agents synced, {len(errors)} errors")
        
        return {
            'synced_count': synced_count,
            'errors': errors
        }
        
    except Exception as e:
        logger.error(f"Error in sync_all_user_calendars: {e}", exc_info=True)
        log_activity(
            action="Calendar sync task failed",
            details={'error': str(e)},
            level=LogLevel.ERROR
        )
        raise


def sync_pending_calls():
    """
    Periodic task to sync call status from ElevenLabs API for calls that haven't been updated.
    Runs every 15 minutes to check for calls that are still in progress.
    """
    from django.utils import timezone
    from datetime import timedelta
    from .models import CallAttempt
    from .constants import CallStatus
    
    logger.info("Starting pending calls sync task")
    
    try:
        # Find calls that are still in progress and were initiated more than 5 minutes ago
        # (calls should complete within a few minutes)
        cutoff_time = timezone.now() - timedelta(minutes=5)
        
        pending_calls = CallAttempt.objects.filter(
            status__in=[CallStatus.INITIATED, CallStatus.IN_PROGRESS, CallStatus.SCHEDULED],
            external_call_id__isnull=False,
            executed_at__lt=cutoff_time
        )
        
        synced_count = 0
        for call_attempt in pending_calls:
            try:
                if sync_call_status_from_api(call_attempt):
                    synced_count += 1
            except Exception as e:
                logger.error(f"Error syncing call {call_attempt.id}: {e}", exc_info=True)
        
        logger.info(f"Pending calls sync completed: {synced_count} calls synced out of {pending_calls.count()}")
        
        return {
            'synced_count': synced_count,
            'total_pending': pending_calls.count()
        }
        
    except Exception as e:
        logger.error(f"Error in sync_pending_calls: {e}", exc_info=True)
        log_activity(
            action="Pending calls sync task failed",
            details={'error': str(e)},
            level=LogLevel.ERROR
        )
        raise
