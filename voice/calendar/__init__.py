"""
Calendar abstraction layer.

Usage:
    from voice.calendar import get_calendar_provider
    cal = get_calendar_provider()
    events = cal.get_events_for_date(user, date.today())
"""

import logging

from decouple import config

from .base import CalendarProvider
from .google import GoogleCalendarProvider

logger = logging.getLogger(__name__)

CALENDAR_PROVIDERS = {
    "google": GoogleCalendarProvider,
}

_cached_provider = None


def get_calendar_provider() -> CalendarProvider:
    """
    Return the configured calendar provider instance.

    Reads CALENDAR_PROVIDER from settings (.env), defaults to 'google'.
    Instance is cached for the process lifetime.
    """
    global _cached_provider
    if _cached_provider is not None:
        return _cached_provider

    provider_name = config("CALENDAR_PROVIDER", default="google").lower()
    provider_cls = CALENDAR_PROVIDERS.get(provider_name)
    if provider_cls is None:
        raise ValueError(
            f"Unknown calendar provider '{provider_name}'. "
            f"Available: {', '.join(CALENDAR_PROVIDERS.keys())}"
        )
    _cached_provider = provider_cls()
    logger.info(f"Calendar provider initialized: {provider_name}")
    return _cached_provider
