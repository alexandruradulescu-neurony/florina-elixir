"""
Google Calendar provider implementation.

Wraps the existing google_calendar service into the CalendarProvider interface.
The heavy lifting (OAuth, API calls) is delegated to voice/services/google_calendar.py
which remains the source of truth for Google-specific logic.
"""

import logging
from datetime import date, datetime, timedelta
from datetime import time as dt_time

from decouple import config
from django.utils import timezone

from voice.utils import convert_to_utc

from .base import CalendarProvider

logger = logging.getLogger(__name__)


class GoogleCalendarProvider(CalendarProvider):
    """Google Calendar integration via Google Calendar API v3."""

    def __init__(self):
        self.client_id = config("GOOGLE_CLIENT_ID", default="")
        self.client_secret = config("GOOGLE_CLIENT_SECRET", default="")

    def is_configured(self) -> bool:
        return bool(self.client_id and self.client_secret)

    def authenticate(self, user, session=None) -> bool:
        from voice.services.google_calendar import get_google_calendar_service

        service = get_google_calendar_service(user, session=session)
        return service is not None

    def get_events_for_date(self, user, target_date: date, session=None) -> list[dict]:
        from voice.services.google_calendar import get_google_calendar_service

        service = get_google_calendar_service(user, session=session)
        if not service:
            return []

        day_start = timezone.make_aware(datetime.combine(target_date, dt_time.min))
        day_end = timezone.make_aware(datetime.combine(target_date, dt_time.max))

        try:
            result = (
                service.events()
                .list(
                    calendarId="primary",
                    timeMin=day_start.isoformat(),
                    timeMax=day_end.isoformat(),
                    singleEvents=True,
                    orderBy="startTime",
                )
                .execute()
            )
        except Exception as e:
            logger.error(f"Google Calendar API error: {e}", exc_info=True)
            return []

        events = []
        for item in result.get("items", []):
            event = self._normalize_event(item)
            if event:
                events.append(event)
        return events

    def setup_push_notifications(self, user, webhook_url: str, session=None) -> dict:
        from voice.services.google_calendar import setup_google_calendar_watch

        return setup_google_calendar_watch(user, webhook_url, session=session)

    def stop_push_notifications(self, user, channel_id: str = None, session=None) -> dict:
        from voice.services.google_calendar import stop_google_calendar_watch

        return stop_google_calendar_watch(user, channel_id=channel_id, session=session)

    def get_auth_url(self, redirect_uri: str, state: str) -> str | None:
        from google_auth_oauthlib.flow import Flow

        from voice.services.google_calendar import SCOPES

        if not self.is_configured():
            return None

        flow = Flow.from_client_config(
            {
                "web": {
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                    "token_uri": "https://oauth2.googleapis.com/token",
                }
            },
            scopes=SCOPES,
            redirect_uri=redirect_uri,
        )
        auth_url, _ = flow.authorization_url(
            access_type="offline",
            include_granted_scopes="true",
            state=state,
            prompt="consent",
        )
        return auth_url

    def handle_auth_callback(self, user, auth_code: str, redirect_uri: str, session=None) -> dict:
        from google_auth_oauthlib.flow import Flow

        from voice.models import GoogleOauthCredential
        from voice.services.google_calendar import SCOPES

        if not self.is_configured():
            return {"success": False, "error": "Google Calendar not configured"}

        try:
            flow = Flow.from_client_config(
                {
                    "web": {
                        "client_id": self.client_id,
                        "client_secret": self.client_secret,
                        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                        "token_uri": "https://oauth2.googleapis.com/token",
                    }
                },
                scopes=SCOPES,
                redirect_uri=redirect_uri,
            )
            flow.fetch_token(code=auth_code)
            credentials = flow.credentials

            # Persist to database
            expires_at = None
            if credentials.expiry:
                expires_at = credentials.expiry
                if timezone.is_naive(expires_at):
                    expires_at = timezone.make_aware(expires_at)

            GoogleOauthCredential.objects.update_or_create(
                user=user,
                defaults={
                    "token": credentials.token,
                    "refresh_token": credentials.refresh_token or "",
                    "token_uri": credentials.token_uri,
                    "client_id": credentials.client_id,
                    "client_secret": credentials.client_secret,
                    "scopes": list(credentials.scopes or []),
                    "expires_at": expires_at,
                },
            )

            # Also store in session for backward compat
            if session is not None:
                session["google_credentials"] = {
                    "token": credentials.token,
                    "refresh_token": credentials.refresh_token,
                    "token_uri": credentials.token_uri,
                    "client_id": credentials.client_id,
                    "client_secret": credentials.client_secret,
                    "scopes": list(credentials.scopes or []),
                }

            return {"success": True}
        except Exception as e:
            logger.error(f"Google Calendar auth callback failed: {e}", exc_info=True)
            return {"success": False, "error": str(e)}

    # ------------------------------------------------------------------ #
    # Normalization
    # ------------------------------------------------------------------ #

    @staticmethod
    def _normalize_event(item: dict) -> dict | None:
        """Convert a raw Google Calendar event to the standard format."""
        event_id = item.get("id")
        if not event_id:
            return None

        start_raw = item.get("start", {}).get("dateTime") or item.get("start", {}).get("date")
        end_raw = item.get("end", {}).get("dateTime") or item.get("end", {}).get("date")

        if start_raw:
            start_time = datetime.fromisoformat(start_raw.replace("Z", "+00:00"))
            if start_time.tzinfo is None:
                start_time = timezone.make_aware(start_time)
            start_time = convert_to_utc(start_time)
        else:
            start_time = timezone.now()

        if end_raw:
            end_time = datetime.fromisoformat(end_raw.replace("Z", "+00:00"))
            if end_time.tzinfo is None:
                end_time = timezone.make_aware(end_time)
            end_time = convert_to_utc(end_time)
        else:
            end_time = start_time + timedelta(hours=1)

        attendees = [att.get("email") for att in item.get("attendees", []) if att.get("email")]

        return {
            "id": event_id,
            "title": item.get("summary", "Untitled Meeting"),
            "start_time": start_time,
            "end_time": end_time,
            "attendees": attendees,
            "description": item.get("description", ""),
            "raw": item,
        }
