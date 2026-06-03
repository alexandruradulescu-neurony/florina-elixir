"""
Pipedrive CRM Integration Service.

Handles all interactions with Pipedrive API including:
- Domain-based organization search
- Deal management
- Note synchronization
"""
import logging
from typing import Any

from voice.constants import LogLevel
from voice.models import Meeting

from .logging import log_activity

logger = logging.getLogger(__name__)


def extract_domain_from_email(email: str) -> str | None:
    """
    Extract domain from email address.

    Args:
        email: Email address (e.g., 'alex@hightouch.one')

    Returns:
        Domain string (e.g., 'hightouch.one') or None if invalid
    """
    if not email or '@' not in email:
        return None

    # Split email and get domain part
    parts = email.split('@')
    if len(parts) == 2:
        domain = parts[1].strip().lower()
        # Basic validation - domain should have at least one dot
        if '.' in domain and len(domain) > 3:
            return domain

    return None


def extract_domains_from_meeting(meeting: Meeting) -> list[str]:
    """
    Extract all unique domains from meeting attendees.

    Args:
        meeting: Meeting instance

    Returns:
        List of unique domain strings
    """
    domains = []
    if not meeting.attendees:
        return domains

    for email in meeting.attendees:
        domain = extract_domain_from_email(email)
        if domain and domain not in domains:
            domains.append(domain)

    return domains


def get_pipedrive_api_client():
    """
    Get authenticated Pipedrive API client.

    Returns:
        Tuple of (requests session, base_url) or (None, None) if credentials missing
    """
    import requests
    from decouple import config

    api_token = config('PIPEDRIVE_API_TOKEN', default='')
    domain = config('PIPEDRIVE_DOMAIN', default='')

    if not api_token or not domain:
        return None, None

    # Create session with authentication
    session = requests.Session()
    session.params = {'api_token': api_token}
    base_url = f"https://{domain}.pipedrive.com/api/v1"

    return session, base_url


def find_pipedrive_organization_by_domain(domain: str) -> dict[str, Any] | None:
    """
    Find Pipedrive organization by domain.
    Searches organizations by domain in name, domain field, or custom fields.

    Args:
        domain: Domain to search for (e.g., 'hightouch.one')

    Returns:
        Organization dictionary from Pipedrive API or None if not found
    """
    client, base_url = get_pipedrive_api_client()
    if not client or not base_url:
        return None

    try:
        # Search organizations by domain
        # Try searching in organization name and domain fields
        response = client.get(
            f"{base_url}/organizations/search",
            params={'term': domain, 'fields': 'name'}
        )

        if response.status_code == 200:
            data = response.json()
            if data.get('success') and data.get('data') and data['data'].get('items'):
                items = data['data']['items']
                # Check each result to see if domain matches
                for item in items:
                    org_data = item.get('item', {})
                    org_name = org_data.get('name', '').lower()

                    # Check if domain is in organization name
                    if domain in org_name:
                        # Get full organization details
                        org_id = org_data.get('id')
                        if org_id:
                            org_response = client.get(f"{base_url}/organizations/{org_id}")
                            if org_response.status_code == 200:
                                org_data_full = org_response.json()
                                if org_data_full.get('success') and org_data_full.get('data'):
                                    return org_data_full['data']

        return None

    except Exception as e:
        logger.error(f"Error searching Pipedrive organization by domain: {e}", exc_info=True)
        return None


def get_pipedrive_deals_for_organization(org_id: int) -> list[dict[str, Any]]:
    """
    Get all deals associated with a Pipedrive organization.

    Args:
        org_id: Pipedrive organization ID

    Returns:
        List of deal dictionaries, sorted by relevance (open deals first)
    """
    client, base_url = get_pipedrive_api_client()
    if not client or not base_url:
        return []

    try:
        response = client.get(f"{base_url}/organizations/{org_id}/deals")

        if response.status_code == 200:
            data = response.json()
            if data.get('success') and data.get('data'):
                deals = data['data']
                # Sort deals: open/active deals first, then by update time
                deals_sorted = sorted(
                    deals,
                    key=lambda d: (
                        0 if d.get('status') in ['open', 'won'] else 1,  # Open/won deals first
                        -int(d.get('update_time', 0) or 0)  # Most recent first
                    )
                )
                return deals_sorted

        return []

    except Exception as e:
        logger.error(f"Error getting deals for organization {org_id}: {e}", exc_info=True)
        return []


def get_pipedrive_deal_by_meeting(meeting: Meeting) -> dict[str, Any] | None:
    """
    Find Pipedrive deal associated with a meeting.
    Uses meeting external_id, customer name, or domain-based search.

    Args:
        meeting: Meeting instance

    Returns:
        Deal dictionary from Pipedrive API or None if not found
    """
    client, base_url = get_pipedrive_api_client()
    if not client or not base_url:
        return None

    try:
        # Try to find deal by external ID (if meeting came from Pipedrive)
        if meeting.external_id:
            response = client.get(f"{base_url}/deals/{meeting.external_id}")
            if response.status_code == 200:
                data = response.json()
                if data.get('success') and data.get('data'):
                    return data['data']

        # If not found, search by customer name
        if meeting.customer_name:
            response = client.get(
                f"{base_url}/deals/search",
                params={'term': meeting.customer_name, 'fields': 'title'}
            )
            if response.status_code == 200:
                data = response.json()
                if data.get('success') and data.get('data') and data['data'].get('items'):
                    # Return first matching deal
                    items = data['data']['items']
                    if items:
                        deal_id = items[0].get('item', {}).get('id')
                        if deal_id:
                            deal_response = client.get(f"{base_url}/deals/{deal_id}")
                            if deal_response.status_code == 200:
                                deal_data = deal_response.json()
                                if deal_data.get('success') and deal_data.get('data'):
                                    return deal_data['data']

        # Domain-based search as fallback
        domains = extract_domains_from_meeting(meeting)
        for domain in domains:
            # Find organization by domain
            organization = find_pipedrive_organization_by_domain(domain)
            if organization:
                org_id = organization.get('id')
                if org_id:
                    # Get deals for this organization
                    deals = get_pipedrive_deals_for_organization(org_id)
                    if deals:
                        # Return first deal (already sorted by relevance)
                        return deals[0]

        return None

    except Exception as e:
        logger.error(f"Error searching Pipedrive deal: {e}", exc_info=True)
        log_activity(
            meeting=meeting,
            action="Pipedrive deal search failed",
            details={'error': str(e)},
            level=LogLevel.ERROR
        )
        return None


def create_or_update_deal(meeting: Meeting) -> dict[str, Any] | None:
    """
    Create or update a Pipedrive deal from a meeting.

    Args:
        meeting: Meeting instance

    Returns:
        Deal dictionary from Pipedrive API or None if creation failed
    """
    client, base_url = get_pipedrive_api_client()
    if not client or not base_url:
        return None

    try:
        # Check if deal already exists
        existing_deal = get_pipedrive_deal_by_meeting(meeting)

        deal_data = {
            'title': meeting.title,
            'expected_close_date': meeting.start_time.strftime('%Y-%m-%d'),
        }

        if meeting.customer_name:
            deal_data['person_name'] = meeting.customer_name

        if existing_deal:
            # Update existing deal
            deal_id = existing_deal['id']
            response = client.put(
                f"{base_url}/deals/{deal_id}",
                json=deal_data
            )

            if response.status_code == 200:
                data = response.json()
                if data.get('success'):
                    log_activity(
                        meeting=meeting,
                        action="Pipedrive deal updated",
                        details={'deal_id': deal_id}
                    )
                    return data.get('data')
        else:
            # Create new deal
            response = client.post(
                f"{base_url}/deals",
                json=deal_data
            )

            if response.status_code == 200 or response.status_code == 201:
                data = response.json()
                if data.get('success'):
                    deal = data.get('data')
                    # Update meeting with Pipedrive deal ID
                    if deal and deal.get('id'):
                        meeting.external_id = str(deal['id'])
                        meeting.save()

                    log_activity(
                        meeting=meeting,
                        action="Pipedrive deal created",
                        details={'deal_id': deal.get('id') if deal else None}
                    )
                    return deal

        return None

    except Exception as e:
        logger.error(f"Error creating/updating Pipedrive deal: {e}", exc_info=True)
        log_activity(
            meeting=meeting,
            action="Pipedrive deal creation/update failed",
            details={'error': str(e)},
            level=LogLevel.ERROR
        )
        return None


def sync_note_to_pipedrive(deal_id: str | None, text: str, meeting: Meeting) -> dict[str, Any]:
    """
    Sync a note (transcript or summary) to Pipedrive deal.

    Args:
        deal_id: Pipedrive deal ID (optional, will be determined from meeting if None)
        text: Text content to sync (transcript or summary)
        meeting: Meeting instance

    Returns:
        Dictionary with sync result: {'success': bool, 'note_id': str, 'error': str}
    """
    result = {'success': False, 'note_id': None, 'error': None}

    client, base_url = get_pipedrive_api_client()
    if not client or not base_url:
        error_msg = "Pipedrive API credentials not configured"
        result['error'] = error_msg
        log_activity(
            meeting=meeting,
            action="Pipedrive note sync failed - no credentials",
            details={'error': error_msg},
            level=LogLevel.WARNING
        )
        return result

    try:
        # Get deal ID if not provided
        if not deal_id:
            deal = get_pipedrive_deal_by_meeting(meeting)
            if deal:
                deal_id = str(deal['id'])
            else:
                # Try to create deal if it doesn't exist
                new_deal = create_or_update_deal(meeting)
                if new_deal:
                    deal_id = str(new_deal['id'])
                else:
                    error_msg = "Could not find or create Pipedrive deal"
                    result['error'] = error_msg
                    log_activity(
                        meeting=meeting,
                        action="Pipedrive note sync failed - no deal",
                        details={'error': error_msg},
                        level=LogLevel.ERROR
                    )
                    return result

        if not deal_id:
            error_msg = "No Pipedrive deal ID available"
            result['error'] = error_msg
            return result

        # Create note in Pipedrive
        note_data = {
            'content': text,
            'deal_id': deal_id,
            'pinned_to_deal_flag': 1  # Pin note to deal
        }

        # Add meeting context to note
        note_title = f"Voice Call - {meeting.title}"
        if meeting.customer_name:
            note_title += f" ({meeting.customer_name})"

        note_data['subject'] = note_title

        response = client.post(
            f"{base_url}/notes",
            json=note_data
        )

        if response.status_code in [200, 201]:
            data = response.json()
            if data.get('success'):
                note = data.get('data')
                note_id = note.get('id') if note else None

                result['success'] = True
                result['note_id'] = str(note_id) if note_id else None

                log_activity(
                    meeting=meeting,
                    action="Note synced to Pipedrive",
                    details={
                        'deal_id': deal_id,
                        'note_id': note_id,
                        'note_length': len(text)
                    }
                )
            else:
                error_msg = data.get('error', 'Unknown error')
                result['error'] = error_msg
                log_activity(
                    meeting=meeting,
                    action="Pipedrive note creation failed",
                    details={'deal_id': deal_id, 'error': error_msg},
                    level=LogLevel.ERROR
                )
        else:
            error_msg = f"HTTP {response.status_code}: {response.text}"
            result['error'] = error_msg
            log_activity(
                meeting=meeting,
                action="Pipedrive API error",
                details={'deal_id': deal_id, 'error': error_msg},
                level=LogLevel.ERROR
            )

    except Exception as e:
        error_msg = f"Unexpected error syncing to Pipedrive: {str(e)}"
        result['error'] = error_msg
        logger.error(error_msg, exc_info=True)
        log_activity(
            meeting=meeting,
            action="Pipedrive sync exception",
            details={'error': error_msg},
            level=LogLevel.ERROR
        )

    return result
