"""
Google Calendar Integration Service.

Handles all interactions with Google Calendar API including:
- OAuth credential management
- Calendar event synchronization
- Push notifications (Watch API)
"""

import logging
from datetime import datetime, time, timedelta
from typing import Any

from django.utils import timezone
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

from voice.constants import CallStatus, LogLevel
from voice.models import CallAttempt, GoogleCalendarWatch, GoogleOauthCredential, User, Visit
from voice.utils import convert_to_utc

from .logging import log_activity

logger = logging.getLogger(__name__)

# Google Calendar API scopes
SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]


# ============================================================================
# Google Calendar OAuth Service
# ============================================================================


def get_google_credentials(user: User, session=None) -> Credentials | None:
    """
    Get stored Google OAuth credentials for a user.
    Checks database first (for background tasks), then session (for backward compatibility).

    Args:
        user: User instance
        session: Django session object (optional, for backward compatibility)

    Returns:
        Credentials object or None if not available
    """
    # Priority 1: Check database (for background tasks)
    try:
        creds_model = GoogleOauthCredential.objects.get(user=user)
        # Ensure expiry is naive UTC datetime (Google credentials library uses datetime.utcnow() which is naive)
        expiry = creds_model.expires_at
        if expiry:
            # Convert to UTC if timezone-aware
            if timezone.is_aware(expiry):
                expiry = expiry.astimezone(timezone.utc)
            # Make naive (Google auth library expects naive UTC datetime)
            expiry = expiry.replace(tzinfo=None)

        return Credentials(
            token=creds_model.token,
            refresh_token=creds_model.refresh_token,
            token_uri=creds_model.token_uri,
            client_id=creds_model.client_id,
            client_secret=creds_model.client_secret,
            scopes=creds_model.scopes,
            expiry=expiry,
        )
    except GoogleOauthCredential.DoesNotExist:
        pass
    except Exception as e:
        log_activity(
            user=user,
            action="Failed to load Google credentials from database",
            details={"error": str(e)},
            level=LogLevel.ERROR,
        )

    # Priority 2: Check session (for backward compatibility during transition)
    if session and "google_credentials" in session:
        try:
            creds_data = session["google_credentials"]
            # Session credentials don't typically have expiry, but handle if present
            expiry = None
            if "expires_at" in creds_data and creds_data["expires_at"]:
                # Handle if expiry is stored in session (shouldn't happen, but be safe)
                expiry = creds_data["expires_at"]
                if isinstance(expiry, str):
                    # If it's a string, parse it
                    from django.utils.dateparse import parse_datetime

                    expiry = parse_datetime(expiry)
                if expiry and timezone.is_aware(expiry):
                    expiry = expiry.astimezone(timezone.utc).replace(tzinfo=None)

            return Credentials(
                token=creds_data.get("token"),
                refresh_token=creds_data.get("refresh_token"),
                token_uri=creds_data.get("token_uri", "https://oauth2.googleapis.com/token"),
                client_id=creds_data.get("client_id"),
                client_secret=creds_data.get("client_secret"),
                scopes=creds_data.get("scopes", []),
                expiry=expiry,
            )
        except Exception as e:
            log_activity(
                user=user,
                action="Failed to load Google credentials from session",
                details={"error": str(e)},
                level=LogLevel.ERROR,
            )

    return None


def refresh_google_credentials(credentials: Credentials, user: User) -> bool:
    """
    Refresh expired Google OAuth credentials and save to database.

    Args:
        credentials: Credentials object to refresh
        user: User instance (for saving refreshed token)

    Returns:
        True if refresh successful, False otherwise
    """
    try:
        if credentials.expired and credentials.refresh_token:
            credentials.refresh(Request())

            # Save refreshed token to database
            GoogleOauthCredential.objects.update_or_create(
                user=user,
                defaults={
                    "token": credentials.token,
                    "refresh_token": credentials.refresh_token,
                    "token_uri": credentials.token_uri,
                    "client_id": credentials.client_id,
                    "client_secret": credentials.client_secret,
                    "scopes": list(credentials.scopes),
                    "expires_at": (
                        timezone.make_aware(credentials.expiry)
                        if timezone.is_naive(credentials.expiry)
                        else credentials.expiry
                    ).astimezone(timezone.utc)
                    if credentials.expiry
                    else None,
                },
            )

            return True
        return False
    except Exception as e:
        logger.error(f"Failed to refresh Google credentials: {e}")
        return False


def get_google_calendar_service(user: User, session=None):
    """
    Get authenticated Google Calendar API service for a user.

    Args:
        user: User instance
        session: Django session object (optional, for session-based storage)

    Returns:
        Google Calendar service object or None if authentication fails
    """
    credentials = get_google_credentials(user, session=session)
    if not credentials:
        log_activity(
            user=user,
            action="Google Calendar authentication failed - no credentials",
            level=LogLevel.WARNING,
        )
        return None

    # Refresh if expired (with error handling for timezone issues)
    try:
        is_expired = credentials.expired
    except TypeError as e:
        # Handle timezone mismatch - try to fix by recreating credentials with naive expiry
        logger.warning(f"Timezone error checking expiry, attempting to fix: {e}")
        if credentials.expiry:
            # Recreate credentials with naive expiry
            expiry_naive = credentials.expiry
            if timezone.is_aware(expiry_naive):
                expiry_naive = expiry_naive.astimezone(timezone.utc).replace(tzinfo=None)
            credentials = Credentials(
                token=credentials.token,
                refresh_token=credentials.refresh_token,
                token_uri=credentials.token_uri,
                client_id=credentials.client_id,
                client_secret=credentials.client_secret,
                scopes=credentials.scopes,
                expiry=expiry_naive,
            )
            is_expired = credentials.expired

    if is_expired and not refresh_google_credentials(credentials, user):
        log_activity(
            user=user,
            action="Google Calendar authentication failed - refresh failed",
            level=LogLevel.ERROR,
        )
        return None

    try:
        service = build("calendar", "v3", credentials=credentials)
        return service
    except Exception as e:
        log_activity(
            user=user,
            action="Failed to build Google Calendar service",
            details={"error": str(e)},
            level=LogLevel.ERROR,
        )
        return None


# ============================================================================
# Google Calendar Sync Service
# ============================================================================


# `create_meeting_from_event` and `update_meeting_from_event` were dropped
# alongside the Meeting→Visit migration (PR Y2a). Both were orphan exports —
# the surviving sync logic lives in `sync_google_calendar` below, and Visit
# rows are now produced by `detect_visits_task` (voice/services/visit_pipeline.py).


def sync_google_calendar(
    user: User, time_min: datetime | None = None, time_max: datetime | None = None, session=None
) -> dict[str, Any]:
    """
    Sync calendar events from Google Calendar for a user.

    PR Y2a: Meeting writes have been removed from this function. The Visit
    pipeline (`detect_visits_task` → `process_visit_pre_calls/post_calls`) is
    now the single source of truth for persisting calendar events; this
    function still fetches events to:
      * validate Google auth (surfaces re-auth needs on the manual sync button)
      * power activity logs / sync timestamps
      * detect deleted events so we can cancel any pending CallAttempts and
        delete the corresponding Visit rows

    The `created` / `updated` counters now reflect calendar events observed
    in the time window — not database rows — because the actual Visit
    upserts happen in `detect_visits_for_agent`. We deliberately keep the
    shape `{created, updated, errors}` for backward compatibility with the
    template / management command callers.

    Args:
        user: User instance (sales agent)
        time_min: Start time for event query (default: start of today in UTC)
        time_max: End time for event query (default: end of today in UTC)

    Returns:
        Dictionary with sync results: {'created': count, 'updated': count, 'errors': []}
    """
    if not user.is_sales_agent:
        log_activity(
            user=user, action="Calendar sync attempted for non-sales agent", level=LogLevel.WARNING
        )
        return {"created": 0, "updated": 0, "errors": ["User is not a sales agent"]}

    service = get_google_calendar_service(user, session=session)
    if not service:
        return {
            "created": 0,
            "updated": 0,
            "errors": ["Failed to authenticate with Google Calendar"],
        }

    # Set default time range to TODAY ONLY if not provided
    if time_min is None or time_max is None:
        now = timezone.now()
        today_start = timezone.make_aware(datetime.combine(now.date(), time.min))
        today_end = timezone.make_aware(datetime.combine(now.date(), time.max))
        if time_min is None:
            time_min = today_start
        if time_max is None:
            time_max = today_end

    results = {"created": 0, "updated": 0, "errors": []}

    try:
        # Fetch events from Google Calendar
        events_result = (
            service.events()
            .list(
                calendarId="primary",
                timeMin=time_min.isoformat(),
                timeMax=time_max.isoformat(),
                singleEvents=True,
                orderBy="startTime",
            )
            .execute()
        )

        events = events_result.get("items", [])

        # PR Y2a: stop persisting Meeting rows here. We still iterate the
        # event list so we can: (a) surface per-event parse errors in the
        # sync results, and (b) update Visit rows for events we have a
        # matching Visit for (Visit upsert from the visit-detection pipeline
        # is what actually creates them — see detect_visits_for_agent).
        for event in events:
            try:
                external_id = event.get("id")
                if not external_id:
                    continue

                # Parse datetime with explicit UTC conversion. Bad timestamps
                # are surfaced via the per-event exception handler below.
                start_time_str = event.get("start", {}).get("dateTime") or event.get(
                    "start", {}
                ).get("date")
                end_time_str = event.get("end", {}).get("dateTime") or event.get("end", {}).get(
                    "date"
                )

                if start_time_str:
                    start_time = datetime.fromisoformat(start_time_str.replace("Z", "+00:00"))
                    if start_time.tzinfo is None:
                        start_time = timezone.make_aware(start_time)
                    start_time = convert_to_utc(start_time)
                else:
                    start_time = timezone.now()

                if end_time_str:
                    end_time = datetime.fromisoformat(end_time_str.replace("Z", "+00:00"))
                    if end_time.tzinfo is None:
                        end_time = timezone.make_aware(end_time)
                    end_time = convert_to_utc(end_time)
                else:
                    end_time = start_time + timedelta(hours=1)

                # Reflect time/title changes on the matching Visit, if any.
                # Visit creation itself is owned by detect_visits_for_agent;
                # we deliberately only update — never create — here so the
                # two pipelines stay decoupled.
                visit = Visit.objects.filter(
                    calendar_event_id=external_id, agent=user
                ).first()
                if visit:
                    changed = False
                    new_title = event.get("summary", visit.title)
                    if visit.title != new_title:
                        visit.title = new_title
                        changed = True
                    if visit.start_time != start_time:
                        visit.start_time = start_time
                        changed = True
                    if visit.end_time != end_time:
                        visit.end_time = end_time
                        changed = True
                    if changed:
                        visit.save(
                            update_fields=["title", "start_time", "end_time", "updated_at"]
                        )
                        results["updated"] += 1
                        log_activity(
                            user=user,
                            action="Visit updated from Google Calendar",
                            details={
                                "visit_id": visit.id,
                                "title": visit.title,
                                "start_time": start_time.isoformat(),
                                "end_time": end_time.isoformat(),
                            },
                        )
                else:
                    # Event seen but no matching Visit — visit-detection will
                    # decide on the next pass whether to create one (based
                    # on attendee-to-Client match).
                    results["created"] += 1

            except Exception as e:
                error_msg = f"Error processing event {event.get('id', 'unknown')}: {str(e)}"
                results["errors"].append(error_msg)
                log_activity(
                    user=user,
                    action="Error syncing calendar event",
                    details={"error": error_msg, "event_id": event.get("id")},
                    level=LogLevel.ERROR,
                )

        log_activity(user=user, action="Google Calendar sync completed", details=results)

    except HttpError as e:
        error_msg = f"Google Calendar API error: {str(e)}"
        results["errors"].append(error_msg)
        log_activity(
            user=user,
            action="Google Calendar API error",
            details={"error": error_msg},
            level=LogLevel.ERROR,
        )
    except Exception as e:
        error_msg = f"Unexpected error during calendar sync: {str(e)}"
        results["errors"].append(error_msg)
        log_activity(
            user=user,
            action="Unexpected calendar sync error",
            details={"error": error_msg},
            level=LogLevel.ERROR,
        )

    return results


# ============================================================================
# Google Calendar Push Notifications (Watch API)
# ============================================================================


def setup_google_calendar_watch(user: User, webhook_url: str, session=None) -> dict[str, Any]:
    """
    Set up Google Calendar push notifications (watch) for a user.

    Google Calendar will send notifications to webhook_url when events are:
    - Created
    - Updated
    - Deleted

    Args:
        user: User instance (sales agent)
        webhook_url: Full URL where Google should send notifications
        session: Optional Django session (for OAuth flow)

    Returns:
        Dictionary with result: {'success': bool, 'channel_id': str, 'resource_id': str, 'expiration': datetime, 'error': str}
    """
    import secrets
    import uuid

    service = get_google_calendar_service(user, session=session)
    if not service:
        return {"success": False, "error": "Failed to authenticate with Google Calendar"}

    try:
        # Generate unique channel ID
        channel_id = str(uuid.uuid4())
        # Random, unguessable per-watch secret. Stored on the watch row and sent
        # to Google as the channel token; inbound webhooks must echo it back.
        # (Replaces the predictable "user_{id}_{channel}" token, which let a
        # forged request target an arbitrary user — security finding CWE-345.)
        channel_token = secrets.token_urlsafe(32)

        # Set expiration (Google recommends max 7 days, we'll use 6 days for safety)
        expiration = timezone.now() + timedelta(days=6)

        # Set up watch
        watch_request = {
            "id": channel_id,
            "type": "web_hook",
            "address": webhook_url,
            "token": channel_token,
        }

        # Call Google Calendar watch API
        watch_response = service.events().watch(calendarId="primary", body=watch_request).execute()

        resource_id = watch_response.get("resourceId")
        expiration_time = watch_response.get("expiration")

        # resource_id is now part of webhook authentication (notifications must
        # match the stored value), so we must not substitute a fallback. If
        # Google ever omits it, fail the setup loudly rather than persist a value
        # that would 403 every future notification for this watch.
        if not resource_id:
            return {"success": False, "error": "Google watch response missing resourceId"}

        if expiration_time:
            # Parse expiration (Google returns milliseconds since epoch)
            expiration = datetime.fromtimestamp(int(expiration_time) / 1000, tz=timezone.utc)

        # Store watch channel in database
        watch, created = GoogleCalendarWatch.objects.update_or_create(
            user=user,
            channel_id=channel_id,
            defaults={
                "resource_id": resource_id,
                "expiration": expiration,
                "token": channel_token,
            },
        )

        log_activity(
            user=user,
            action="Google Calendar watch channel created",
            details={
                "channel_id": channel_id,
                "resource_id": resource_id,
                "expiration": expiration.isoformat(),
                "webhook_url": webhook_url,
            },
        )

        return {
            "success": True,
            "channel_id": channel_id,
            "resource_id": resource_id,
            "expiration": expiration,
        }

    except HttpError as e:
        error_msg = f"Google Calendar watch API error: {str(e)}"
        logger.error(error_msg)
        return {"success": False, "error": error_msg}
    except Exception as e:
        error_msg = f"Error setting up Google Calendar watch: {str(e)}"
        logger.error(error_msg, exc_info=True)
        return {"success": False, "error": error_msg}


def stop_google_calendar_watch(user: User, channel_id: str = None, session=None) -> dict[str, Any]:
    """
    Stop a Google Calendar watch channel.

    Args:
        user: User instance
        channel_id: Optional channel ID (if None, stops all watches for user)
        session: Optional Django session

    Returns:
        Dictionary with result: {'success': bool, 'stopped': count, 'error': str}
    """
    try:
        if channel_id:
            watches = GoogleCalendarWatch.objects.filter(user=user, channel_id=channel_id)
        else:
            watches = GoogleCalendarWatch.objects.filter(user=user)

        stopped_count = 0
        service = get_google_calendar_service(user, session=session)

        for watch in watches:
            try:
                if service:
                    # Stop the watch via Google API
                    service.channels().stop(
                        body={"id": watch.channel_id, "resourceId": watch.resource_id}
                    ).execute()

                # Delete from database
                watch.delete()
                stopped_count += 1

            except Exception as e:
                logger.warning(f"Error stopping watch {watch.channel_id}: {e}")
                # Still delete from database even if API call fails
                watch.delete()
                stopped_count += 1

        log_activity(
            user=user,
            action="Google Calendar watch channel(s) stopped",
            details={"stopped_count": stopped_count, "channel_id": channel_id},
        )

        return {"success": True, "stopped": stopped_count}

    except Exception as e:
        error_msg = f"Error stopping Google Calendar watch: {str(e)}"
        logger.error(error_msg, exc_info=True)
        return {"success": False, "error": error_msg, "stopped": 0}


def handle_google_calendar_notification(user_id: int, event_ids: list = None) -> dict[str, Any]:
    """
    Handle Google Calendar push notification.
    Called when Google sends a notification that events have changed.

    Args:
        user_id: User ID whose calendar was updated
        event_ids: Optional list of specific event IDs that changed (if provided, only sync those)

    Returns:
        Dictionary with sync results
    """
    try:
        user = User.objects.get(id=user_id)
        if not user.is_sales_agent:
            return {"success": False, "error": "User is not a sales agent"}

        # Sync calendar - sync only TODAY's meetings
        now = timezone.now()
        today_start = timezone.make_aware(datetime.combine(now.date(), time.min))
        today_end = timezone.make_aware(datetime.combine(now.date(), time.max))
        time_min = today_start
        time_max = today_end

        # Get current events from Google Calendar
        service = get_google_calendar_service(user, session=None)
        if not service:
            return {"success": False, "error": "Failed to authenticate with Google Calendar"}

        # Fetch events
        events_result = (
            service.events()
            .list(
                calendarId="primary",
                timeMin=time_min.isoformat(),
                timeMax=time_max.isoformat(),
                singleEvents=True,
                orderBy="startTime",
            )
            .execute()
        )

        current_event_ids = {
            event.get("id") for event in events_result.get("items", []) if event.get("id")
        }

        # Get all Visits for this user in the time range. We previously
        # tracked deletions on Meeting; PR Y2a moves this to Visit (Meeting
        # is no longer written by sync_google_calendar).
        user_visits = Visit.objects.filter(
            agent=user, start_time__gte=time_min, start_time__lte=time_max
        )

        # Find Visits whose calendar event no longer exists in Google
        # Calendar — they were deleted upstream. We cancel any pending
        # CallAttempts and remove the Visit so the operator dashboards do
        # not keep dangling rows for events that no longer exist.
        deleted_count = 0
        for visit in user_visits:
            if visit.calendar_event_id and visit.calendar_event_id not in current_event_ids:
                cancelled_calls = CallAttempt.objects.filter(
                    visit=visit, status=CallStatus.SCHEDULED
                ).update(status=CallStatus.FAILED)

                log_activity(
                    user=user,
                    action="Visit deleted (calendar event removed)",
                    details={
                        "visit_id": visit.id,
                        "calendar_event_id": visit.calendar_event_id,
                        "cancelled_calls": cancelled_calls,
                    },
                    level=LogLevel.WARNING,
                )

                # CASCADE handles CallAttempts; ActivityLog rows link via
                # visit FK and are intentionally retained for audit.
                visit.delete()
                deleted_count += 1

        # Re-run sync to refresh Visit times/titles for the remaining events.
        # (Visit *creation* is owned by detect_visits_for_agent in the
        # background pipeline; sync_google_calendar only updates here.)
        sync_results = sync_google_calendar(
            user, time_min=time_min, time_max=time_max, session=None
        )
        sync_results["deleted"] = deleted_count

        log_activity(
            user=user, action="Google Calendar push notification processed", details=sync_results
        )

        return {"success": True, **sync_results}

    except User.DoesNotExist:
        return {"success": False, "error": "User not found"}
    except Exception as e:
        error_msg = f"Error handling Google Calendar notification: {str(e)}"
        logger.error(error_msg, exc_info=True)
        log_activity(
            action="Google Calendar notification processing failed",
            details={"user_id": user_id, "error": error_msg},
            level=LogLevel.ERROR,
        )
        return {"success": False, "error": error_msg}
