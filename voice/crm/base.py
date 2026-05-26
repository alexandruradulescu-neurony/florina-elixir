"""
Abstract base class for CRM providers.

To add a new CRM, subclass CRMProvider and implement all abstract methods.
Then register it in voice/crm/__init__.py CRM_PROVIDERS dict.
"""
from abc import ABC, abstractmethod
from typing import Optional


class CRMProvider(ABC):
    """Interface that all CRM providers must implement."""

    @abstractmethod
    def get_client(self, client_id: str) -> Optional[dict]:
        """
        Fetch a single client/organization by CRM ID.

        Returns:
            Dict with at least: id, name, domain, industry, or None if not found.
        """

    @abstractmethod
    def search_client_by_domain(self, domain: str) -> Optional[dict]:
        """
        Search for a client/organization by email domain.

        Returns:
            Dict with client data or None if not found.
        """

    @abstractmethod
    def get_deals_for_client(self, client_id: str) -> list[dict]:
        """
        Get all deals/opportunities for a client.

        Returns:
            List of deal dicts sorted by relevance (open first, most recent first).
        """

    @abstractmethod
    def get_deal(self, deal_id: str) -> Optional[dict]:
        """
        Fetch a single deal by ID.

        Returns:
            Deal dict or None.
        """

    @abstractmethod
    def get_interaction_history(self, client_id: str) -> list[dict]:
        """
        Get notes, activities, and communication history for a client.

        Returns:
            List of interaction dicts, most recent first.
        """

    @abstractmethod
    def get_contacts_for_client(self, client_id: str) -> list[dict]:
        """
        Get contact persons associated with a client/organization.

        Returns:
            List of contact dicts with at least: name, email, phone, role.
        """

    @abstractmethod
    def post_note_to_deal(self, deal_id: str, text: str, subject: str = '') -> dict:
        """
        Create a note on a deal.

        Returns:
            Dict with: success (bool), note_id (str or None), error (str or None).
        """

    @abstractmethod
    def sync_clients(self) -> list[dict]:
        """
        Bulk pull all clients/organizations from CRM for local sync.

        Returns:
            List of client dicts with at least: id, name, domain.
        """

    @abstractmethod
    def search_deal_by_term(self, term: str) -> Optional[dict]:
        """
        Search for a deal by a search term (name, title, etc.).

        Returns:
            Deal dict or None.
        """

    def is_configured(self) -> bool:
        """Check if this provider has valid credentials configured."""
        return False
