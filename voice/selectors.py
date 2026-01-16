"""
Database query selectors for the voice app.
Following DRY principles to centralize database queries.
"""
from django.utils import timezone
from datetime import timedelta
from .models import VoicePrompt, Meeting, CallAttempt
from .constants import CallPhase, CallStatus, PRE_MEETING_OFFSETS, POST_MEETING_OFFSETS, SCHEDULER_WINDOW


def get_active_prompt(phase: str) -> VoicePrompt | None:
    """
    Get the active prompt for a given phase.
    
    Args:
        phase: CallPhase value ('PRE' or 'POST')
        
    Returns:
        VoicePrompt instance or None if no active prompt exists
    """
    try:
        return VoicePrompt.objects.get(prompt_type=phase, is_active=True)
    except VoicePrompt.DoesNotExist:
        return None


def get_meeting_by_external_id(external_id: str) -> Meeting | None:
    """
    Find a meeting by its external ID (from Google Calendar or Pipedrive).
    
    Args:
        external_id: External identifier from Google/Pipedrive
        
    Returns:
        Meeting instance or None if not found
    """
    try:
        return Meeting.objects.get(external_id=external_id)
    except Meeting.DoesNotExist:
        return None


def get_call_attempt_by_external_id(external_call_id: str) -> CallAttempt | None:
    """
    Find a call attempt by its external call ID (from ElevenLabs).
    
    Args:
        external_call_id: External call identifier from ElevenLabs (may include Twilio SID)
        
    Returns:
        CallAttempt instance or None if not found
    """
    try:
        return CallAttempt.objects.get(external_call_id=external_call_id)
    except CallAttempt.DoesNotExist:
        return None


def get_meetings_for_pre_call_check() -> list[tuple[Meeting, int]]:
    """
    Find meetings that need pre-meeting calls triggered.
    
    For pre-meeting calls with offset -60:
    - Meeting at 16:00 should get a call at 15:00 (60 min before)
    - We want to find meetings where: meeting.start_time + offset is within current window
    - So: meeting.start_time should be between (now - offset - window/2) and (now - offset + window/2)
    - Since offset is negative (-60), this becomes: (now + 60 - 5) to (now + 60 + 5)
    
    Returns:
        List of tuples (Meeting, offset_minutes) for meetings that need calls
    """
    now = timezone.now()
    results = []
    
    for offset in PRE_MEETING_OFFSETS:
        # Calculate when the call should be made: meeting.start_time + offset (since offset is negative, this is before meeting)
        # We want meetings where this call time is within the current window
        # meeting.start_time + offset should be between (now - window/2) and (now + window/2)
        # Rearranging: meeting.start_time should be between (now - offset - window/2) and (now - offset + window/2)
        # Also allow some past tolerance to catch up on missed calls (extend window backward by 10 minutes)
        window_start = now - timedelta(minutes=offset) - timedelta(minutes=SCHEDULER_WINDOW / 2) - timedelta(minutes=10)
        window_end = now - timedelta(minutes=offset) + timedelta(minutes=SCHEDULER_WINDOW / 2)
        
        # Find meetings where start_time falls in this window
        # Also ensure meeting hasn't started yet (we only do pre-meeting calls before the meeting)
        meetings = Meeting.objects.filter(
            start_time__gte=window_start,
            start_time__lte=window_end,
            start_time__gt=now,  # Meeting hasn't started yet
            agent__is_sales_agent=True
        )
        
        for meeting in meetings:
            # Check if this offset call should be triggered
            if offset == PRE_MEETING_OFFSETS[0]:  # First call (-60 mins)
                # Check if call attempt already exists for this offset
                if not CallAttempt.objects.filter(
                    meeting=meeting,
                    phase=CallPhase.PRE_MEETING,
                    scheduled_offset_minutes=offset
                ).exists():
                    results.append((meeting, offset))
            else:  # Retry call (-30 mins)
                # Only trigger if pre-call is not completed
                if not meeting.is_pre_call_completed:
                    # Check if retry call doesn't exist
                    if not CallAttempt.objects.filter(
                        meeting=meeting,
                        phase=CallPhase.PRE_MEETING,
                        scheduled_offset_minutes=offset
                    ).exists():
                        results.append((meeting, offset))
    
    return results


def get_meetings_for_post_call_check() -> list[tuple[Meeting, int]]:
    """
    Find meetings that need post-meeting calls triggered.
    
    For post-meeting calls with offset +15:
    - Meeting ends at 17:00 should get a call at 17:15 (15 min after)
    - We want to find meetings where: meeting.end_time + offset is within current window
    - So: meeting.end_time should be between (now - offset - window/2) and (now - offset + window/2)
    
    Returns:
        List of tuples (Meeting, offset_minutes) for meetings that need calls
    """
    now = timezone.now()
    results = []
    
    for offset in POST_MEETING_OFFSETS:
        # Calculate when the call should be made: meeting.end_time + offset
        # We want meetings where this call time is within the current window
        # meeting.end_time + offset should be between (now - window/2) and (now + window/2)
        # Rearranging: meeting.end_time should be between (now - offset - window/2) and (now - offset + window/2)
        window_start = now - timedelta(minutes=offset) - timedelta(minutes=SCHEDULER_WINDOW / 2)
        window_end = now - timedelta(minutes=offset) + timedelta(minutes=SCHEDULER_WINDOW / 2)
        
        # Find meetings that ended in this window
        meetings = Meeting.objects.filter(
            end_time__gte=window_start,
            end_time__lte=window_end,
            agent__is_sales_agent=True
        )
        
        for meeting in meetings:
            # Check if this offset call should be triggered
            if offset == POST_MEETING_OFFSETS[0]:  # First call (+15 mins)
                # Check if call attempt already exists for this offset
                if not CallAttempt.objects.filter(
                    meeting=meeting,
                    phase=CallPhase.POST_MEETING,
                    scheduled_offset_minutes=offset
                ).exists():
                    results.append((meeting, offset))
            else:  # Retry call (+30 mins)
                # Only trigger if post-call is not completed
                if not meeting.is_post_call_completed:
                    # Check if retry call doesn't exist
                    if not CallAttempt.objects.filter(
                        meeting=meeting,
                        phase=CallPhase.POST_MEETING,
                        scheduled_offset_minutes=offset
                    ).exists():
                        results.append((meeting, offset))
    
    return results


def get_call_attempts_for_meeting(meeting: Meeting, phase: str = None) -> list[CallAttempt]:
    """
    Get all call attempts for a meeting, optionally filtered by phase.
    
    Args:
        meeting: Meeting instance
        phase: Optional CallPhase to filter by
        
    Returns:
        List of CallAttempt instances
    """
    queryset = CallAttempt.objects.filter(meeting=meeting)
    if phase:
        queryset = queryset.filter(phase=phase)
    return list(queryset.order_by('created_at'))


def get_sales_agents() -> list:
    """
    Get all users marked as sales agents.
    
    Returns:
        List of User instances who are sales agents
    """
    from .models import User
    return list(User.objects.filter(is_sales_agent=True))


def get_recent_activity_logs(limit: int = 100):
    """
    Get recent activity logs.
    
    Args:
        limit: Maximum number of logs to return
        
    Returns:
        QuerySet of ActivityLog instances (for lazy evaluation)
    """
    from .models import ActivityLog
    return ActivityLog.objects.all()[:limit]


def get_system_statistics():
    """
    Get system-wide statistics for superuser dashboard.
    
    Returns:
        Dictionary with system statistics
    """
    from .models import User, Meeting, CallAttempt, ActivityLog
    from .constants import LogLevel
    from datetime import date
    
    today = timezone.now().date()
    today_start = timezone.now().replace(hour=0, minute=0, second=0, microsecond=0)
    today_end = timezone.now().replace(hour=23, minute=59, second=59, microsecond=999999)
    
    calls_today = CallAttempt.objects.filter(created_at__gte=today_start, created_at__lte=today_end)
    completed_calls_today = calls_today.filter(status=CallStatus.COMPLETED)
    
    total_calls = calls_today.count()
    completed_count = completed_calls_today.count()
    success_rate = (completed_count / total_calls * 100) if total_calls > 0 else 0
    
    return {
        'total_users': User.objects.count(),
        'sales_agents': User.objects.filter(is_sales_agent=True).count(),
        'total_meetings': Meeting.objects.count(),
        'upcoming_meetings': Meeting.objects.filter(start_time__gte=timezone.now()).count(),
        'calls_today': total_calls,
        'completed_calls_today': completed_count,
        'success_rate': round(success_rate, 1),
        'total_logs': ActivityLog.objects.count(),
        'error_logs': ActivityLog.objects.filter(level=LogLevel.ERROR).count(),
    }


def get_recent_calls(limit: int = 20):
    """
    Get recent call attempts across all agents.
    
    Args:
        limit: Maximum number of calls to return
        
    Returns:
        List of CallAttempt instances
    """
    return list(CallAttempt.objects.select_related('meeting', 'meeting__agent').order_by('-created_at')[:limit])


def get_failed_calls_today():
    """
    Get meetings where agents missed both pre-meeting call attempts today.
    
    Returns:
        List of dictionaries with meeting and agent info
    """
    from .models import Meeting
    
    today = timezone.now().date()
    today_start = timezone.now().replace(hour=0, minute=0, second=0, microsecond=0)
    today_end = timezone.now().replace(hour=23, minute=59, second=59, microsecond=999999)
    
    # Find meetings that started today
    # Use prefetch_related to avoid N+1 queries
    today_meetings = Meeting.objects.filter(
        start_time__gte=today_start,
        start_time__lte=today_end,
        agent__is_sales_agent=True,
        is_pre_call_completed=False
    ).prefetch_related('call_attempts')
    
    failed_meetings = []
    for meeting in today_meetings:
        # Check if both pre-meeting calls failed
        # Use prefetched call_attempts to avoid additional queries
        pre_calls = meeting.call_attempts.filter(
            phase=CallPhase.PRE_MEETING,
            created_at__gte=today_start,
            created_at__lte=today_end
        )
        
        # Check if both -60 and -30 calls exist and both failed
        call_60 = pre_calls.filter(scheduled_offset_minutes=-60).first()
        call_30 = pre_calls.filter(scheduled_offset_minutes=-30).first()
        
        if call_60 and call_30:
            if (call_60.status in [CallStatus.NO_ANSWER, CallStatus.FAILED] and
                call_30.status in [CallStatus.NO_ANSWER, CallStatus.FAILED]):
                failed_meetings.append({
                    'meeting': meeting,
                    'agent': meeting.agent,
                    'call_60_status': call_60.status,
                    'call_30_status': call_30.status,
                })
    
    return failed_meetings


def get_all_meetings(limit: int = 50, filters: dict = None):
    """
    Get all meetings with optional filters.
    
    Args:
        limit: Maximum number of meetings to return
        filters: Optional dictionary with filter criteria
        
    Returns:
        QuerySet of Meeting instances
    """
    queryset = Meeting.objects.select_related('agent').order_by('-start_time')
    
    if filters:
        if 'agent_id' in filters:
            queryset = queryset.filter(agent_id=filters['agent_id'])
        if 'start_date' in filters:
            queryset = queryset.filter(start_time__gte=filters['start_date'])
        if 'end_date' in filters:
            queryset = queryset.filter(start_time__lte=filters['end_date'])
    
    return queryset[:limit]


def get_activity_logs_filtered(level: str = None, user_id: int = None, limit: int = 100):
    """
    Get filtered activity logs.
    
    Args:
        level: Optional log level filter
        user_id: Optional user ID filter
        limit: Maximum number of logs to return
        
    Returns:
        QuerySet of ActivityLog instances
    """
    from .models import ActivityLog
    
    queryset = ActivityLog.objects.select_related('user', 'meeting').order_by('-timestamp')
    
    if level:
        queryset = queryset.filter(level=level)
    if user_id:
        queryset = queryset.filter(user_id=user_id)
    
    return queryset[:limit]


def get_agent_meetings(agent, limit: int = 20):
    """
    Get meetings for a specific agent.
    
    Args:
        agent: User instance (sales agent)
        limit: Maximum number of meetings to return
        
    Returns:
        QuerySet of Meeting instances
    """
    return Meeting.objects.filter(agent=agent).order_by('-start_time')[:limit]


def get_agent_call_statistics(agent):
    """
    Get call statistics for a sales agent.
    
    Args:
        agent: User instance (sales agent)
        
    Returns:
        Dictionary with call statistics
    """
    agent_calls = CallAttempt.objects.filter(meeting__agent=agent)
    total = agent_calls.count()
    completed = agent_calls.filter(status=CallStatus.COMPLETED).count()
    failed = agent_calls.filter(status=CallStatus.FAILED).count()
    no_answer = agent_calls.filter(status=CallStatus.NO_ANSWER).count()
    
    success_rate = (completed / total * 100) if total > 0 else 0
    
    return {
        'total': total,
        'completed': completed,
        'failed': failed,
        'no_answer': no_answer,
        'success_rate': round(success_rate, 1),
    }


def get_upcoming_meetings_for_agent(agent, limit: int = 10):
    """
    Get upcoming meetings for an agent with timeline data.
    
    Args:
        agent: User instance (sales agent)
        limit: Maximum number of meetings to return
        
    Returns:
        QuerySet of Meeting instances
    """
    return Meeting.objects.filter(
        agent=agent,
        start_time__gte=timezone.now()
    ).order_by('start_time')[:limit]


def get_agent_timeline_data(agent, date=None):
    """
    Get timeline data for agent's day (calls, meetings, debriefs).
    
    Args:
        agent: User instance (sales agent)
        date: Optional date (defaults to today)
        
    Returns:
        List of timeline items with type, time, status, and data
    """
    from .models import Meeting, CallAttempt
    from datetime import datetime, time
    
    if not date:
        date = timezone.now().date()
    
    # Create date range for the day
    date_start = timezone.make_aware(datetime.combine(date, time.min))
    date_end = timezone.make_aware(datetime.combine(date, time.max))
    
    timeline_items = []
    
    # Get meetings for this date
    meetings = Meeting.objects.filter(
        agent=agent,
        start_time__gte=date_start,
        start_time__lte=date_end
    ).order_by('start_time')
    
    for meeting in meetings:
        # Pre-meeting calls
        pre_calls = CallAttempt.objects.filter(
            meeting=meeting,
            phase=CallPhase.PRE_MEETING
        ).order_by('created_at')
        
        for call in pre_calls:
            # Use scheduled_time if available (from pre-programming), otherwise calculate it
            if call.scheduled_time:
                call_time = call.scheduled_time
            else:
                # Fallback: calculate from meeting start time + offset
                call_time = meeting.start_time + timedelta(minutes=call.scheduled_offset_minutes)
            
            timeline_items.append({
                'type': 'pre_call',
                'time': call_time,
                'meeting': meeting,
                'call': call,
                'status': call.status,
                'offset': call.scheduled_offset_minutes,
            })
        
        # Meeting itself
        timeline_items.append({
            'type': 'meeting',
            'time': meeting.start_time,
            'meeting': meeting,
            'status': 'scheduled',
        })
        
        # Post-meeting calls
        post_calls = CallAttempt.objects.filter(
            meeting=meeting,
            phase=CallPhase.POST_MEETING
        ).order_by('created_at')
        
        for call in post_calls:
            # Use scheduled_time if available (from pre-programming), otherwise calculate it
            if call.scheduled_time:
                call_time = call.scheduled_time
            else:
                # Fallback: calculate from meeting end time + offset
                call_time = meeting.end_time + timedelta(minutes=call.scheduled_offset_minutes)
            
            timeline_items.append({
                'type': 'post_call',
                'time': call_time,
                'meeting': meeting,
                'call': call,
                'status': call.status,
                'offset': call.scheduled_offset_minutes,
            })
    
    # Sort by time
    timeline_items.sort(key=lambda x: x['time'])
    
    return timeline_items
