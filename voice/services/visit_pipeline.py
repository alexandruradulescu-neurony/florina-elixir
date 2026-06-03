"""
Visit Detection Pipeline.

Reads calendar events, matches attendee domains to known Clients,
creates Visit objects, resolves CRM deals, and assigns methodology.

Flow:
  1. Fetch today's events from calendar provider
  2. For each event, extract attendee email domains
  3. Match domains against local Client records
  4. If match → create/update Visit linked to Client + Agent
  5. If no match → skip (not a client meeting)
  6. Resolve CRM deal for the client
  7. Assign methodology (visit override > agent default > system default)
"""
import logging
from datetime import date

from django.utils import timezone

from voice.calendar import get_calendar_provider
from voice.constants import VisitStatus
from voice.crm import get_crm_provider
from voice.models import Client, User, Visit

from .logging import log_activity

logger = logging.getLogger(__name__)


def extract_domain_from_email(email: str) -> str | None:
    """Extract domain from an email address."""
    if not email or '@' not in email:
        return None
    parts = email.split('@')
    if len(parts) == 2:
        domain = parts[1].strip().lower()
        if '.' in domain and len(domain) > 3:
            return domain
    return None


def match_client_by_attendees(attendees: list[str]) -> Client | None:
    """
    Try to find a Client by matching attendee email domains.

    Args:
        attendees: List of email addresses from calendar event.

    Returns:
        First matched Client or None.
    """
    seen_domains = set()
    for email in attendees:
        domain = extract_domain_from_email(email)
        if not domain or domain in seen_domains:
            continue
        seen_domains.add(domain)

        # Exact match on local Client.domain
        client = Client.objects.filter(domain=domain).first()
        if client:
            return client

    return None


def resolve_crm_deal(client: Client) -> str | None:
    """
    Find the most relevant open deal for a client in the CRM.

    Returns:
        CRM deal ID string, or None.
    """
    crm = get_crm_provider()
    if not crm.is_configured():
        return None

    try:
        deals = crm.get_deals_for_client(client.crm_id)
        if deals:
            # First deal is most relevant (open, most recent)
            return str(deals[0].get('id', ''))
    except Exception as e:
        logger.warning(f"Failed to resolve CRM deal for client {client.crm_id}: {e}")
    return None


def detect_visits_for_agent(agent: User, target_date: date = None) -> dict:
    """
    Read an agent's calendar for the given date and create Visits
    for events that match known clients.

    Args:
        agent: Sales agent User instance.
        target_date: Date to scan (defaults to today).

    Returns:
        Dict with: created (int), updated (int), skipped (int), errors (list[str]).
    """
    if target_date is None:
        target_date = timezone.now().date()

    results = {'created': 0, 'updated': 0, 'skipped': 0, 'errors': []}

    cal = get_calendar_provider()
    if not cal.authenticate(agent):
        results['errors'].append(f"Agent {agent.username}: calendar not authenticated")
        return results

    try:
        events = cal.get_events_for_date(agent, target_date)
    except Exception as e:
        error_msg = f"Failed to fetch calendar for {agent.username}: {e}"
        logger.error(error_msg, exc_info=True)
        results['errors'].append(error_msg)
        return results

    for event in events:
        try:
            attendees = event.get('attendees', [])
            client = match_client_by_attendees(attendees)

            if not client:
                results['skipped'] += 1
                continue

            event_id = event['id']

            # Check if Visit already exists for this calendar event
            existing = Visit.objects.filter(
                calendar_event_id=event_id,
                agent=agent,
            ).first()

            if existing:
                # Update times if changed
                changed = False
                if existing.start_time != event['start_time']:
                    existing.start_time = event['start_time']
                    changed = True
                if existing.end_time != event['end_time']:
                    existing.end_time = event['end_time']
                    changed = True
                if existing.title != event['title']:
                    existing.title = event['title']
                    changed = True

                if changed:
                    existing.save()
                    results['updated'] += 1
                continue

            # Resolve CRM deal
            crm_deal_id = resolve_crm_deal(client)

            # Create Visit
            visit = Visit.objects.create(
                agent=agent,
                client=client,
                calendar_event_id=event_id,
                title=event['title'],
                start_time=event['start_time'],
                end_time=event['end_time'],
                attendees=attendees,
                crm_deal_id=crm_deal_id or '',
                status=VisitStatus.PLANNED,
            )

            results['created'] += 1

            log_activity(
                user=agent,
                action=f"Visit created: {visit.title}",
                details={
                    'visit_id': visit.id,
                    'client': client.name,
                    'crm_deal_id': crm_deal_id,
                    'start_time': visit.start_time.isoformat(),
                },
            )

        except Exception as e:
            error_msg = f"Error processing event {event.get('id', '?')}: {e}"
            logger.error(error_msg, exc_info=True)
            results['errors'].append(error_msg)

    return results


def detect_visits_for_all_agents(target_date: date = None) -> dict:
    """
    Run visit detection for all sales agents.

    Returns:
        Dict with: total_created, total_updated, total_skipped, agent_results (list), errors (list).
    """
    if target_date is None:
        target_date = timezone.now().date()

    agents = User.objects.filter(is_sales_agent=True, is_active=True)
    totals = {
        'total_created': 0,
        'total_updated': 0,
        'total_skipped': 0,
        'agent_results': [],
        'errors': [],
    }

    for agent in agents:
        result = detect_visits_for_agent(agent, target_date)
        totals['total_created'] += result['created']
        totals['total_updated'] += result['updated']
        totals['total_skipped'] += result['skipped']
        totals['errors'].extend(result['errors'])
        totals['agent_results'].append({
            'agent': agent.username,
            **result,
        })

    log_activity(
        action="Visit detection completed for all agents",
        details={
            'date': str(target_date),
            'agents_processed': len(totals['agent_results']),
            'total_created': totals['total_created'],
            'total_updated': totals['total_updated'],
            'total_skipped': totals['total_skipped'],
        },
    )

    return totals
