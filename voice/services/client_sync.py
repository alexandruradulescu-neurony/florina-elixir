"""
Client Sync Service.

Syncs client/organization data from the CRM into the local Client model.
Supports full sync (all clients) and single-client refresh.
"""
import logging
from typing import Optional

from django.utils import timezone

from voice.models import Client
from voice.constants import LogLevel
from voice.crm import get_crm_provider
from .logging import log_activity

logger = logging.getLogger(__name__)


def sync_all_clients() -> dict:
    """
    Full sync: pull all clients from CRM and upsert into local Client model.

    Returns:
        Dict with: created (int), updated (int), errors (list[str]).
    """
    crm = get_crm_provider()
    if not crm.is_configured():
        return {'created': 0, 'updated': 0, 'errors': ['CRM not configured']}

    results = {'created': 0, 'updated': 0, 'errors': []}
    now = timezone.now()

    try:
        raw_clients = crm.sync_clients()
    except Exception as e:
        error_msg = f"CRM sync_clients call failed: {e}"
        logger.error(error_msg, exc_info=True)
        results['errors'].append(error_msg)
        return results

    for raw in raw_clients:
        try:
            crm_id = raw.get('id')
            if not crm_id:
                continue

            defaults = {
                'name': raw.get('name', ''),
                'domain': raw.get('domain', '') or None,
                'industry': raw.get('industry', '') or None,
                'raw_data': raw.get('raw', raw),
                'last_synced_at': now,
            }

            client, created = Client.objects.update_or_create(
                crm_id=str(crm_id),
                defaults=defaults,
            )

            if created:
                results['created'] += 1
            else:
                results['updated'] += 1

        except Exception as e:
            error_msg = f"Error syncing client {raw.get('id', '?')}: {e}"
            logger.error(error_msg, exc_info=True)
            results['errors'].append(error_msg)

    log_activity(
        action="Client sync completed",
        details=results,
        level=LogLevel.INFO,
    )
    return results


def sync_single_client(crm_id: str) -> Optional[Client]:
    """
    Refresh a single client from CRM by its CRM ID.

    Returns:
        Updated Client instance, or None on failure.
    """
    crm = get_crm_provider()
    if not crm.is_configured():
        return None

    try:
        raw = crm.get_client(crm_id)
        if not raw:
            return None

        now = timezone.now()
        defaults = {
            'name': raw.get('name', ''),
            'domain': raw.get('domain', '') or None,
            'industry': raw.get('industry', '') or None,
            'raw_data': raw.get('raw', raw),
            'last_synced_at': now,
        }

        client, _ = Client.objects.update_or_create(
            crm_id=str(crm_id),
            defaults=defaults,
        )
        return client
    except Exception as e:
        logger.error(f"Error syncing single client {crm_id}: {e}", exc_info=True)
        return None


def enrich_client_from_crm(client: Client) -> Client:
    """
    Fetch contacts, deals, and interaction history from CRM for a local Client.
    Call this before pre-call prompt generation to ensure fresh data.

    Returns:
        Updated Client instance.
    """
    crm = get_crm_provider()
    if not crm.is_configured():
        return client

    try:
        contacts = crm.get_contacts_for_client(client.crm_id)
        client.contacts = contacts
    except Exception as e:
        logger.warning(f"Failed to fetch contacts for client {client.crm_id}: {e}")

    try:
        deals = crm.get_deals_for_client(client.crm_id)
        client.deal_history = deals
    except Exception as e:
        logger.warning(f"Failed to fetch deals for client {client.crm_id}: {e}")

    try:
        history = crm.get_interaction_history(client.crm_id)
        client.interaction_history = history
    except Exception as e:
        logger.warning(f"Failed to fetch interaction history for client {client.crm_id}: {e}")

    client.last_synced_at = timezone.now()
    client.save()

    log_activity(
        action=f"Client enriched from CRM: {client.name}",
        details={
            'crm_id': client.crm_id,
            'contacts_count': len(client.contacts),
            'deals_count': len(client.deal_history),
            'interactions_count': len(client.interaction_history),
        },
    )
    return client
