"""
Database query selectors for the voice app.
Following DRY principles to centralize database queries.
"""
from django.utils import timezone
from datetime import timedelta
from .models import VoicePrompt, Meeting, CallAttempt, Client, Visit, Methodology
from .constants import CallPhase, CallStatus, VisitStatus, PRE_MEETING_OFFSETS, POST_MEETING_OFFSETS, SCHEDULER_WINDOW


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


# ============================================================================
# Client Selectors
# ============================================================================

def get_client_by_domain(domain: str):
    """Find a client by email domain."""
    return Client.objects.filter(domain=domain).first()


def get_client_by_crm_id(crm_id: str):
    """Find a client by CRM ID."""
    try:
        return Client.objects.get(crm_id=crm_id)
    except Client.DoesNotExist:
        return None


def get_all_clients(limit=100):
    """Get all clients ordered by name."""
    return Client.objects.all()[:limit]


def get_stale_clients(hours=24):
    """Get clients that haven't been synced recently."""
    cutoff = timezone.now() - timedelta(hours=hours)
    return Client.objects.filter(
        last_synced_at__lt=cutoff
    ) | Client.objects.filter(last_synced_at__isnull=True)


def get_clients_with_stats():
    """
    Get all clients enriched with visit count, last visit date, and sync status.
    Returns list of dicts for template consumption.
    """
    from .models import User
    clients = Client.objects.all().order_by('name')
    now = timezone.now()
    result = []

    for client in clients:
        visits = Visit.objects.filter(client=client)
        total_visits = visits.count()
        last_visit = visits.order_by('-start_time').first()
        agents = User.objects.filter(
            is_sales_agent=True,
            id__in=visits.values_list('agent_id', flat=True).distinct()
        )

        is_stale = (
            client.last_synced_at is None
            or (now - client.last_synced_at).total_seconds() > 86400
        )

        result.append({
            'client': client,
            'total_visits': total_visits,
            'last_visit': last_visit,
            'agent_count': agents.count(),
            'has_summary': bool(client.ai_summary),
            'has_contacts': bool(client.contacts and len(client.contacts) > 0),
            'is_stale': is_stale,
        })

    return result


def get_client_detail(client_id):
    """
    Get a single client with related visits, calls, and agents.
    Returns dict with enriched data or None if not found.
    """
    from .models import User, CallAttempt
    try:
        client = Client.objects.get(id=client_id)
    except Client.DoesNotExist:
        return None

    visits = Visit.objects.filter(
        client=client
    ).select_related('agent', 'methodology').order_by('-start_time')

    agents = User.objects.filter(
        is_sales_agent=True,
        id__in=visits.values_list('agent_id', flat=True).distinct()
    ).select_related('default_methodology')

    total_visits = visits.count()
    completed_visits = visits.filter(status=VisitStatus.COMPLETE).count()

    recent_calls = CallAttempt.objects.filter(
        visit__client=client
    ).select_related('visit', 'visit__agent').order_by('-created_at')[:10]

    return {
        'client': client,
        'visits': visits[:20],
        'agents': agents,
        'recent_calls': recent_calls,
        'total_visits': total_visits,
        'completed_visits': completed_visits,
        'completion_rate': round(completed_visits / total_visits * 100) if total_visits else 0,
    }


# ============================================================================
# Visit Selectors
# ============================================================================

def get_visits_for_date(target_date=None, agent=None):
    """Get all visits for a given date, optionally filtered by agent."""
    if target_date is None:
        target_date = timezone.now().date()

    qs = Visit.objects.filter(
        start_time__date=target_date,
    ).select_related('agent', 'client', 'methodology')

    if agent:
        qs = qs.filter(agent=agent)

    return qs.order_by('start_time')


def get_visits_for_range(start_date, end_date, agent=None):
    """Get all visits within a date range, optionally filtered by agent."""
    from datetime import datetime, time as dt_time
    start_dt = timezone.make_aware(datetime.combine(start_date, dt_time.min))
    end_dt = timezone.make_aware(datetime.combine(end_date, dt_time.max))

    qs = Visit.objects.filter(
        start_time__gte=start_dt,
        start_time__lte=end_dt,
    ).select_related('agent', 'client', 'methodology')

    if agent:
        qs = qs.filter(agent=agent)

    return qs.order_by('start_time')


def get_visits_needing_pre_call():
    """
    Get planned visits where pre-call hasn't happened yet
    and the visit is coming up within the configured window.
    """
    from .models import GlobalSettings
    settings = GlobalSettings.load()
    offset = abs(settings.pre_call_offset_minutes)

    now = timezone.now()
    cutoff = now + timedelta(minutes=offset + 5)  # small buffer

    return Visit.objects.filter(
        status=VisitStatus.PLANNED,
        start_time__lte=cutoff,
        start_time__gt=now,
    ).select_related('agent', 'client', 'methodology')


def get_visits_needing_post_call():
    """
    Get visits where the meeting has ended but post-call hasn't happened yet.
    """
    from .models import GlobalSettings
    settings = GlobalSettings.load()
    offset = settings.post_call_offset_minutes

    now = timezone.now()

    return Visit.objects.filter(
        status__in=[VisitStatus.PLANNED, VisitStatus.PRE_CALL_DONE, VisitStatus.IN_PROGRESS],
        end_time__lte=now - timedelta(minutes=offset),
    ).select_related('agent', 'client', 'methodology')


def get_agent_visits(agent, limit=20):
    """Get recent visits for a specific agent."""
    return Visit.objects.filter(
        agent=agent,
    ).select_related('client', 'methodology').order_by('-start_time')[:limit]


def get_visit_by_calendar_event(event_id: str, agent=None):
    """Find a visit by its calendar event ID."""
    qs = Visit.objects.filter(calendar_event_id=event_id)
    if agent:
        qs = qs.filter(agent=agent)
    return qs.first()


# ============================================================================
# Methodology Selectors
# ============================================================================

def get_active_methodologies():
    """Get all active methodologies."""
    return Methodology.objects.filter(is_active=True).order_by('name')


def get_methodology_by_id(methodology_id: int):
    """Get a methodology by ID."""
    try:
        return Methodology.objects.get(id=methodology_id)
    except Methodology.DoesNotExist:
        return None


# ============================================================================
# Dashboard Selectors
# ============================================================================

def get_dashboard_visit_summary(target_date=None):
    """
    Get visit counts grouped by status for a given date.
    Returns dict with total and per-status counts.
    """
    if target_date is None:
        target_date = timezone.now().date()

    visits = Visit.objects.filter(start_time__date=target_date)
    total = visits.count()

    status_counts = {}
    for status_val in VisitStatus.values:
        status_counts[status_val] = visits.filter(status=status_val).count()

    return {
        'total': total,
        'planned': status_counts.get(VisitStatus.PLANNED, 0),
        'pre_call_done': status_counts.get(VisitStatus.PRE_CALL_DONE, 0),
        'in_progress': status_counts.get(VisitStatus.IN_PROGRESS, 0),
        'post_call_done': status_counts.get(VisitStatus.POST_CALL_DONE, 0),
        'complete': status_counts.get(VisitStatus.COMPLETE, 0),
    }


def get_agent_readiness(target_date=None):
    """
    Get per-agent readiness data for today's visits.
    Returns list of dicts with agent info and their visit/call stats.
    """
    from .models import User
    if target_date is None:
        target_date = timezone.now().date()

    agents = User.objects.filter(is_sales_agent=True).order_by('username')
    result = []

    for agent in agents:
        visits = Visit.objects.filter(
            agent=agent, start_time__date=target_date
        ).select_related('client', 'methodology')

        visit_count = visits.count()
        pre_calls_done = visits.filter(
            status__in=[VisitStatus.PRE_CALL_DONE, VisitStatus.IN_PROGRESS,
                        VisitStatus.POST_CALL_DONE, VisitStatus.COMPLETE]
        ).count()
        post_calls_done = visits.filter(
            status__in=[VisitStatus.POST_CALL_DONE, VisitStatus.COMPLETE]
        ).count()
        completed = visits.filter(status=VisitStatus.COMPLETE).count()

        methodology = agent.default_methodology
        has_phone = bool(agent.phone_number)

        # Determine overall status
        if visit_count == 0:
            agent_status = 'idle'
        elif not has_phone:
            agent_status = 'error'
        elif completed == visit_count:
            agent_status = 'done'
        elif pre_calls_done == visit_count:
            agent_status = 'good'
        else:
            agent_status = 'pending'

        result.append({
            'agent': agent,
            'visit_count': visit_count,
            'pre_calls_done': pre_calls_done,
            'post_calls_done': post_calls_done,
            'completed': completed,
            'methodology': methodology,
            'has_phone': has_phone,
            'status': agent_status,
            'visits': list(visits.order_by('start_time')[:5]),
        })

    return result


def get_dashboard_action_items(target_date=None):
    """
    Get urgent items requiring manager attention.
    Returns list of action item dicts with type, severity, message, and link context.
    """
    from .models import User
    if target_date is None:
        target_date = timezone.now().date()

    now = timezone.now()
    items = []

    # 1. Visits starting soon with no pre-call
    upcoming_no_precall = Visit.objects.filter(
        status=VisitStatus.PLANNED,
        start_time__date=target_date,
        start_time__gt=now,
        start_time__lte=now + timedelta(hours=2),
    ).select_related('agent', 'client')

    for visit in upcoming_no_precall:
        minutes_until = int((visit.start_time - now).total_seconds() / 60)
        items.append({
            'type': 'no_precall',
            'severity': 'error' if minutes_until < 30 else 'warning',
            'message': f"{visit.agent.get_full_name() or visit.agent.username} meets {visit.client.name if visit.client else visit.title} in {minutes_until}min — no pre-call done",
            'visit_id': visit.id,
        })

    # 2. Failed call attempts today
    failed_calls = CallAttempt.objects.filter(
        created_at__date=target_date,
        status__in=[CallStatus.FAILED, CallStatus.NO_ANSWER],
    ).select_related('visit', 'visit__agent', 'visit__client', 'meeting', 'meeting__agent')

    for call in failed_calls[:5]:
        if call.visit:
            agent_name = call.visit.agent.get_full_name() or call.visit.agent.username
            context = call.visit.client.name if call.visit.client else call.visit.title
        elif call.meeting:
            agent_name = call.meeting.agent.username
            context = call.meeting.title
        else:
            continue
        items.append({
            'type': 'failed_call',
            'severity': 'error',
            'message': f"Call to {agent_name} failed ({call.get_status_display()}) — {context}",
            'visit_id': call.visit_id,
        })

    # 3. Visits with no methodology
    no_methodology = Visit.objects.filter(
        start_time__date=target_date,
        methodology__isnull=True,
    ).select_related('agent')

    for visit in no_methodology:
        agent = visit.agent
        if not agent.default_methodology:
            from .models import GlobalSettings
            settings = GlobalSettings.load()
            if not settings.default_methodology:
                items.append({
                    'type': 'no_methodology',
                    'severity': 'warning',
                    'message': f"{agent.get_full_name() or agent.username} has a visit with no methodology at any level",
                    'visit_id': visit.id,
                })

    # 4. Agents with no phone number
    agents_no_phone = User.objects.filter(
        is_sales_agent=True,
        phone_number='',
    )
    for agent in agents_no_phone:
        items.append({
            'type': 'no_phone',
            'severity': 'error',
            'message': f"{agent.get_full_name() or agent.username} has no phone number — cannot receive calls",
            'visit_id': None,
        })

    # 5. Pending CRM sync
    pending_sync = Visit.objects.filter(
        status__in=[VisitStatus.POST_CALL_DONE, VisitStatus.COMPLETE],
        crm_synced=False,
        post_call_summary__isnull=False,
    ).exclude(post_call_summary='').select_related('agent', 'client')

    for visit in pending_sync[:3]:
        items.append({
            'type': 'crm_pending',
            'severity': 'info',
            'message': f"CRM sync pending for {visit.client.name if visit.client else visit.title}",
            'visit_id': visit.id,
        })

    # Sort by severity
    severity_order = {'error': 0, 'warning': 1, 'info': 2}
    items.sort(key=lambda x: severity_order.get(x['severity'], 3))

    return items


def get_weekly_summary(target_date=None):
    """
    Get aggregated stats for the current week (Mon-Sun).
    """
    if target_date is None:
        target_date = timezone.now().date()

    # Find Monday of this week
    monday = target_date - timedelta(days=target_date.weekday())
    sunday = monday + timedelta(days=6)

    from datetime import datetime, time as dt_time
    week_start = timezone.make_aware(datetime.combine(monday, dt_time.min))
    week_end = timezone.make_aware(datetime.combine(sunday, dt_time.max))

    visits = Visit.objects.filter(start_time__gte=week_start, start_time__lte=week_end)
    calls = CallAttempt.objects.filter(created_at__gte=week_start, created_at__lte=week_end)

    total_visits = visits.count()
    completed_visits = visits.filter(status=VisitStatus.COMPLETE).count()
    total_calls = calls.count()
    completed_calls = calls.filter(status=CallStatus.COMPLETED).count()
    crm_synced = visits.filter(crm_synced=True).count()

    # Methodology breakdown
    methodology_usage = {}
    for visit in visits.select_related('methodology'):
        m_name = visit.methodology.name if visit.methodology else 'None'
        methodology_usage[m_name] = methodology_usage.get(m_name, 0) + 1

    return {
        'week_start': monday,
        'week_end': sunday,
        'total_visits': total_visits,
        'completed_visits': completed_visits,
        'visit_completion_rate': round(completed_visits / total_visits * 100, 1) if total_visits else 0,
        'total_calls': total_calls,
        'completed_calls': completed_calls,
        'call_success_rate': round(completed_calls / total_calls * 100, 1) if total_calls else 0,
        'crm_synced': crm_synced,
        'methodology_usage': methodology_usage,
    }


def get_recent_post_call_summaries(limit=5):
    """Get the most recent post-call summaries from completed visits."""
    return Visit.objects.filter(
        post_call_summary__isnull=False,
    ).exclude(
        post_call_summary='',
    ).select_related('agent', 'client').order_by('-end_time')[:limit]


def get_next_upcoming_visit():
    """Get the single next upcoming visit (for countdown display)."""
    now = timezone.now()
    return Visit.objects.filter(
        start_time__gt=now,
    ).select_related('agent', 'client').order_by('start_time').first()
