"""
Pipedrive CRM Integration Service.

Handles all interactions with Pipedrive API including:
- Domain-based organization search
- Deal management
- Note synchronization

PR Y2b note: the legacy `Meeting`-typed helpers
(`extract_domains_from_meeting`, `get_pipedrive_deal_by_meeting`,
`create_or_update_deal`, `sync_note_to_pipedrive`) were removed alongside
the Meeting model. The Visit-flow Pipedrive sync goes through the CRM
provider abstraction (see `voice.crm` + `voice/tasks.py` post-call task)
which works directly off `visit.crm_deal_id`.
"""

import logging
from typing import Any

logger = logging.getLogger(__name__)


def extract_domain_from_email(email: str) -> str | None:
    """
    Extract domain from email address.

    Args:
        email: Email address (e.g., 'alex@hightouch.one')

    Returns:
        Domain string (e.g., 'hightouch.one') or None if invalid
    """
    if not email or "@" not in email:
        return None

    # Split email and get domain part
    parts = email.split("@")
    if len(parts) == 2:
        domain = parts[1].strip().lower()
        # Basic validation - domain should have at least one dot
        if "." in domain and len(domain) > 3:
            return domain

    return None


def get_pipedrive_api_client():
    """
    Get authenticated Pipedrive API client.

    Returns:
        Tuple of (requests session, base_url) or (None, None) if credentials missing
    """
    import requests
    from decouple import config

    api_token = config("PIPEDRIVE_API_TOKEN", default="")
    domain = config("PIPEDRIVE_DOMAIN", default="")

    if not api_token or not domain:
        return None, None

    # Create session with authentication
    session = requests.Session()
    session.params = {"api_token": api_token}
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
            f"{base_url}/organizations/search", params={"term": domain, "fields": "name"}
        )

        if response.status_code == 200:
            data = response.json()
            if data.get("success") and data.get("data") and data["data"].get("items"):
                items = data["data"]["items"]
                # Check each result to see if domain matches
                for item in items:
                    org_data = item.get("item", {})
                    org_name = org_data.get("name", "").lower()

                    # Check if domain is in organization name
                    if domain in org_name:
                        # Get full organization details
                        org_id = org_data.get("id")
                        if org_id:
                            org_response = client.get(f"{base_url}/organizations/{org_id}")
                            if org_response.status_code == 200:
                                org_data_full = org_response.json()
                                if org_data_full.get("success") and org_data_full.get("data"):
                                    return org_data_full["data"]

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
            if data.get("success") and data.get("data"):
                deals = data["data"]
                # Sort deals: open/active deals first, then by update time
                deals_sorted = sorted(
                    deals,
                    key=lambda d: (
                        0 if d.get("status") in ["open", "won"] else 1,  # Open/won deals first
                        -int(d.get("update_time", 0) or 0),  # Most recent first
                    ),
                )
                return deals_sorted

        return []

    except Exception as e:
        logger.error(f"Error getting deals for organization {org_id}: {e}", exc_info=True)
        return []
