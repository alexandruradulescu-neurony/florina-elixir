"""
Abstract base class for Calendar providers.

To add a new calendar provider, subclass CalendarProvider and implement all abstract methods.
Then register it in voice/calendar/__init__.py CALENDAR_PROVIDERS dict.
"""
from abc import ABC, abstractmethod
from datetime import date


class CalendarProvider(ABC):
    """Interface that all calendar providers must implement."""

    @abstractmethod
    def authenticate(self, user, session=None) -> bool:
        """
        Check if user has valid calendar credentials.

        Args:
            user: Django User instance.
            session: Optional Django session for web-based auth flows.

        Returns:
            True if authenticated and ready to make API calls.
        """

    @abstractmethod
    def get_events_for_date(self, user, target_date: date, session=None) -> list[dict]:
        """
        Fetch calendar events for a given date.

        Each returned dict must contain at least:
            - id: str (external event ID)
            - title: str
            - start_time: datetime (timezone-aware)
            - end_time: datetime (timezone-aware)
            - attendees: list[str] (email addresses)
            - description: str

        Args:
            user: Django User instance.
            target_date: Date to fetch events for.
            session: Optional Django session.

        Returns:
            List of normalized event dicts.
        """

    @abstractmethod
    def setup_push_notifications(self, user, webhook_url: str, session=None) -> dict:
        """
        Register a webhook to receive real-time event change notifications.

        Returns:
            Dict with: success (bool), channel_id (str), expiration (datetime), error (str).
        """

    @abstractmethod
    def stop_push_notifications(self, user, channel_id: str = None, session=None) -> dict:
        """
        Unregister push notification webhooks.

        Args:
            user: Django User instance.
            channel_id: Optional specific channel to stop. If None, stops all for user.
            session: Optional Django session.

        Returns:
            Dict with: success (bool), stopped (int), error (str).
        """

    @abstractmethod
    def get_auth_url(self, redirect_uri: str, state: str) -> str | None:
        """
        Generate the OAuth authorization URL for the user to grant access.

        Args:
            redirect_uri: Where to redirect after auth.
            state: CSRF state parameter.

        Returns:
            Authorization URL string, or None if provider doesn't use OAuth.
        """

    @abstractmethod
    def handle_auth_callback(self, user, auth_code: str, redirect_uri: str, session=None) -> dict:
        """
        Exchange authorization code for credentials and store them.

        Args:
            user: Django User instance.
            auth_code: Authorization code from OAuth callback.
            redirect_uri: Redirect URI used in the original auth request.
            session: Optional Django session.

        Returns:
            Dict with: success (bool), error (str).
        """

    def is_configured(self) -> bool:
        """Check if this provider has valid configuration (client ID, etc.)."""
        return False
