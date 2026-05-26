"""
Pipedrive CRM provider implementation.
"""
import logging
from typing import Optional

import requests
from decouple import config

from .base import CRMProvider

logger = logging.getLogger(__name__)


class PipedriveProvider(CRMProvider):
    """Pipedrive CRM integration."""

    def __init__(self):
        self.api_token = config('PIPEDRIVE_API_TOKEN', default='')
        self.domain = config('PIPEDRIVE_DOMAIN', default='')
        self._session = None

    def is_configured(self) -> bool:
        return bool(self.api_token and self.domain)

    @property
    def base_url(self) -> str:
        return f"https://{self.domain}.pipedrive.com/api/v1"

    @property
    def session(self) -> requests.Session:
        if self._session is None:
            self._session = requests.Session()
            self._session.params = {'api_token': self.api_token}
        return self._session

    def _get(self, path: str, **kwargs) -> Optional[dict]:
        """Make a GET request and return parsed JSON data or None."""
        try:
            resp = self.session.get(f"{self.base_url}{path}", **kwargs)
            if resp.status_code == 200:
                body = resp.json()
                if body.get('success'):
                    return body.get('data')
        except Exception as e:
            logger.error(f"Pipedrive GET {path} failed: {e}", exc_info=True)
        return None

    def _post(self, path: str, json_data: dict) -> Optional[dict]:
        """Make a POST request and return parsed JSON data or None."""
        try:
            resp = self.session.post(f"{self.base_url}{path}", json=json_data)
            if resp.status_code in (200, 201):
                body = resp.json()
                if body.get('success'):
                    return body.get('data')
        except Exception as e:
            logger.error(f"Pipedrive POST {path} failed: {e}", exc_info=True)
        return None

    def _put(self, path: str, json_data: dict) -> Optional[dict]:
        """Make a PUT request and return parsed JSON data or None."""
        try:
            resp = self.session.put(f"{self.base_url}{path}", json=json_data)
            if resp.status_code == 200:
                body = resp.json()
                if body.get('success'):
                    return body.get('data')
        except Exception as e:
            logger.error(f"Pipedrive PUT {path} failed: {e}", exc_info=True)
        return None

    # ------------------------------------------------------------------ #
    # CRMProvider interface
    # ------------------------------------------------------------------ #

    def get_client(self, client_id: str) -> Optional[dict]:
        org = self._get(f"/organizations/{client_id}")
        if not org:
            return None
        return self._normalize_client(org)

    def search_client_by_domain(self, domain: str) -> Optional[dict]:
        try:
            resp = self.session.get(
                f"{self.base_url}/organizations/search",
                params={'term': domain, 'fields': 'name'},
            )
            if resp.status_code != 200:
                return None
            body = resp.json()
            items = (body.get('data') or {}).get('items', [])
            for item in items:
                org_data = item.get('item', {})
                if domain.lower() in org_data.get('name', '').lower():
                    org_id = org_data.get('id')
                    if org_id:
                        return self.get_client(str(org_id))
        except Exception as e:
            logger.error(f"Pipedrive search_client_by_domain failed: {e}", exc_info=True)
        return None

    def get_deals_for_client(self, client_id: str) -> list[dict]:
        data = self._get(f"/organizations/{client_id}/deals")
        if not data:
            return []
        deals = sorted(
            data,
            key=lambda d: (
                0 if d.get('status') in ('open', 'won') else 1,
                -(d.get('update_time') or 0) if isinstance(d.get('update_time'), (int, float)) else 0,
            ),
        )
        return [self._normalize_deal(d) for d in deals]

    def get_deal(self, deal_id: str) -> Optional[dict]:
        data = self._get(f"/deals/{deal_id}")
        if not data:
            return None
        return self._normalize_deal(data)

    def get_interaction_history(self, client_id: str) -> list[dict]:
        """Get notes and activities for an organization."""
        interactions = []

        # Get notes
        notes = self._get(f"/organizations/{client_id}/notes") or []
        if isinstance(notes, list):
            for note in notes:
                interactions.append({
                    'type': 'note',
                    'id': str(note.get('id', '')),
                    'content': note.get('content', ''),
                    'date': note.get('add_time', ''),
                    'user': note.get('user', {}).get('name', '') if isinstance(note.get('user'), dict) else '',
                })

        # Get activities
        activities = self._get(f"/organizations/{client_id}/activities") or []
        if isinstance(activities, list):
            for act in activities:
                interactions.append({
                    'type': act.get('type', 'activity'),
                    'id': str(act.get('id', '')),
                    'content': act.get('subject', '') or act.get('note', ''),
                    'date': act.get('due_date', '') or act.get('add_time', ''),
                    'user': act.get('owner_name', ''),
                })

        interactions.sort(key=lambda x: x.get('date', ''), reverse=True)
        return interactions

    def get_contacts_for_client(self, client_id: str) -> list[dict]:
        data = self._get(f"/organizations/{client_id}/persons")
        if not data or not isinstance(data, list):
            return []
        contacts = []
        for person in data:
            emails = person.get('email', [])
            email = emails[0].get('value', '') if emails and isinstance(emails, list) else ''
            phones = person.get('phone', [])
            phone = phones[0].get('value', '') if phones and isinstance(phones, list) else ''
            contacts.append({
                'id': str(person.get('id', '')),
                'name': person.get('name', ''),
                'email': email,
                'phone': phone,
                'role': person.get('job_title', ''),
            })
        return contacts

    def post_note_to_deal(self, deal_id: str, text: str, subject: str = '') -> dict:
        result = {'success': False, 'note_id': None, 'error': None}
        note_data = {
            'content': text,
            'deal_id': deal_id,
            'pinned_to_deal_flag': 1,
        }
        if subject:
            note_data['subject'] = subject
        data = self._post('/notes', note_data)
        if data:
            result['success'] = True
            result['note_id'] = str(data.get('id', ''))
        else:
            result['error'] = 'Failed to create note in Pipedrive'
        return result

    def sync_clients(self) -> list[dict]:
        """Pull all organizations from Pipedrive (paginated)."""
        clients = []
        start = 0
        limit = 100
        while True:
            try:
                resp = self.session.get(
                    f"{self.base_url}/organizations",
                    params={'start': start, 'limit': limit},
                )
                if resp.status_code != 200:
                    break
                body = resp.json()
                if not body.get('success'):
                    break
                data = body.get('data') or []
                for org in data:
                    clients.append(self._normalize_client(org))
                pagination = body.get('additional_data', {}).get('pagination', {})
                if not pagination.get('more_items_in_collection'):
                    break
                start += limit
            except Exception as e:
                logger.error(f"Pipedrive sync_clients pagination error: {e}", exc_info=True)
                break
        return clients

    def search_deal_by_term(self, term: str) -> Optional[dict]:
        try:
            resp = self.session.get(
                f"{self.base_url}/deals/search",
                params={'term': term, 'fields': 'title'},
            )
            if resp.status_code != 200:
                return None
            body = resp.json()
            items = (body.get('data') or {}).get('items', [])
            if items:
                deal_id = items[0].get('item', {}).get('id')
                if deal_id:
                    return self.get_deal(str(deal_id))
        except Exception as e:
            logger.error(f"Pipedrive search_deal_by_term failed: {e}", exc_info=True)
        return None

    # ------------------------------------------------------------------ #
    # Normalization helpers
    # ------------------------------------------------------------------ #

    @staticmethod
    def _normalize_client(org: dict) -> dict:
        """Normalize Pipedrive organization to standard client format."""
        return {
            'id': str(org.get('id', '')),
            'name': org.get('name', ''),
            'domain': (org.get('cc_email', '') or '').split('@')[-1] if org.get('cc_email') else '',
            'industry': org.get('industry', '') or '',
            'address': org.get('address', ''),
            'raw': org,
        }

    @staticmethod
    def _normalize_deal(deal: dict) -> dict:
        """Normalize Pipedrive deal to standard format."""
        return {
            'id': str(deal.get('id', '')),
            'title': deal.get('title', ''),
            'status': deal.get('status', ''),
            'value': deal.get('value', 0),
            'currency': deal.get('currency', ''),
            'stage': deal.get('stage_id', ''),
            'expected_close_date': deal.get('expected_close_date', ''),
            'org_id': str(deal.get('org_id', '')),
            'person_id': str(deal.get('person_id', '')),
            'update_time': deal.get('update_time', ''),
            'raw': deal,
        }
