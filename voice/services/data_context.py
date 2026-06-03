"""
Assembles a database snapshot as text context for the Live Agent chat.
Provides the LLM with current data so it can answer questions accurately.
"""

from datetime import timedelta

from django.utils import timezone


def assemble_data_context():
    """
    Build a text summary of current database state for the LLM.
    Returns a string with structured data the LLM can reference.
    """
    from voice.constants import CallStatus, VisitStatus
    from voice.models import CallAttempt, Client, GlobalSettings, Methodology, User, Visit

    now = timezone.now()
    today = now.date()
    week_start = today - timedelta(days=today.weekday())
    week_end = week_start + timedelta(days=6)

    # Agents
    agents = User.objects.filter(is_sales_agent=True).select_related("default_methodology")
    agent_lines = []
    for a in agents:
        methodology = a.default_methodology.name if a.default_methodology else "None"
        phone = a.phone_number or "No phone"
        agent_lines.append(
            f"  - {a.get_full_name() or a.username} (username: {a.username}, "
            f"methodology: {methodology}, phone: {phone})"
        )

    # Clients
    clients = Client.objects.all().order_by("name")
    client_lines = []
    for c in clients:
        visit_count = Visit.objects.filter(client=c).count()
        client_lines.append(
            f"  - {c.name} (industry: {c.industry or 'N/A'}, "
            f"domain: {c.domain or 'N/A'}, visits: {visit_count})"
        )

    # Today's visits
    today_visits = (
        Visit.objects.filter(start_time__date=today)
        .select_related("agent", "client", "methodology")
        .order_by("start_time")
    )
    visit_lines = []
    for v in today_visits:
        client_name = v.client.name if v.client else "Unknown"
        agent_name = v.agent.get_full_name() or v.agent.username
        methodology = v.methodology.name if v.methodology else "Default"
        visit_lines.append(
            f"  - {v.start_time.strftime('%H:%M')}-{v.end_time.strftime('%H:%M')} "
            f"{agent_name} -> {client_name} [{v.get_status_display()}] "
            f"(methodology: {methodology})"
        )

    # This week's visits summary
    week_visits = Visit.objects.filter(
        start_time__date__gte=week_start,
        start_time__date__lte=week_end,
    )
    week_total = week_visits.count()
    week_complete = week_visits.filter(status=VisitStatus.COMPLETE).count()
    week_planned = week_visits.filter(status=VisitStatus.PLANNED).count()

    # Calls summary
    today_calls = CallAttempt.objects.filter(created_at__date=today)
    total_calls_today = today_calls.count()
    completed_calls_today = today_calls.filter(status=CallStatus.COMPLETED).count()
    failed_calls_today = today_calls.filter(
        status__in=[CallStatus.FAILED, CallStatus.NO_ANSWER]
    ).count()

    all_calls = CallAttempt.objects.all()
    total_calls_ever = all_calls.count()
    completed_calls_ever = all_calls.filter(status=CallStatus.COMPLETED).count()

    # Methodologies
    methodologies = Methodology.objects.filter(is_active=True)
    methodology_lines = []
    for m in methodologies:
        agent_count = User.objects.filter(is_sales_agent=True, default_methodology=m).count()
        methodology_lines.append(f"  - {m.name} (used by {agent_count} agents)")

    # Global settings
    settings = GlobalSettings.load()
    default_method = settings.default_methodology.name if settings.default_methodology else "None"

    context = f"""## Current Date & Time
{now.strftime("%A, %B %d, %Y at %H:%M")}

## Sales Agents ({agents.count()})
{chr(10).join(agent_lines) if agent_lines else "  No agents configured"}

## Clients ({clients.count()})
{chr(10).join(client_lines) if client_lines else "  No clients synced"}

## Today's Visits ({len(visit_lines)})
{chr(10).join(visit_lines) if visit_lines else "  No visits today"}

## This Week (Mon {week_start.strftime("%b %d")} - Sun {week_end.strftime("%b %d")})
  Total: {week_total} | Complete: {week_complete} | Planned: {week_planned}

## Calls
  Today: {total_calls_today} total, {completed_calls_today} completed, {failed_calls_today} failed
  All time: {total_calls_ever} total, {completed_calls_ever} completed

## Active Methodologies ({methodologies.count()})
{chr(10).join(methodology_lines) if methodology_lines else "  No active methodologies"}

## System Settings
  Pre-call offset: {settings.pre_call_offset_minutes} min
  Post-call offset: {settings.post_call_offset_minutes} min
  Default methodology: {default_method}
"""
    return context
