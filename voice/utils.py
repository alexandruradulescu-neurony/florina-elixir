"""
Utility functions for the voice app.
"""

import re
from datetime import datetime, timedelta

from django.utils import timezone
from phonenumbers import (
    NumberParseException,
    PhoneNumberFormat,
    format_number,
    is_possible_number,
    is_valid_number,
    parse,
)


def calculate_call_time(meeting_start: datetime, offset_minutes: int) -> datetime:
    """
    Calculate when a call should be made based on meeting time and offset.

    Args:
        meeting_start: Meeting start time
        offset_minutes: Offset in minutes (negative for pre-meeting, positive for post-meeting)

    Returns:
        Calculated call time
    """
    return meeting_start + timedelta(minutes=offset_minutes)


def calculate_meeting_end_time(meeting_start: datetime, duration_minutes: int = 60) -> datetime:
    """
    Calculate meeting end time from start time and duration.

    Args:
        meeting_start: Meeting start time
        duration_minutes: Meeting duration in minutes (default: 60)

    Returns:
        Calculated end time
    """
    return meeting_start + timedelta(minutes=duration_minutes)


def is_within_time_window(target_time: datetime, window_minutes: int = 5) -> bool:
    """
    Check if current time is within a window around target time.

    Args:
        target_time: Target time to check against
        window_minutes: Window size in minutes (default: 5)

    Returns:
        True if current time is within window, False otherwise
    """
    now = timezone.now()
    window_start = target_time - timedelta(minutes=window_minutes / 2)
    window_end = target_time + timedelta(minutes=window_minutes / 2)

    return window_start <= now <= window_end


def format_phone_number(phone_number: str, default_region: str = "US") -> str | None:
    """
    Format phone number to E.164 format.

    Args:
        phone_number: Phone number string (various formats accepted)
        default_region: Default region code if number doesn't have country code (default: 'US')

    Returns:
        Formatted phone number in E.164 format (e.g., +1234567890) or None if invalid
    """
    if not phone_number:
        return None

    # Remove common formatting characters
    cleaned = re.sub(r"[\s\-\(\)\.]", "", phone_number)

    try:
        parsed_number = parse(cleaned, default_region)

        if is_valid_number(parsed_number):
            return format_number(parsed_number, PhoneNumberFormat.E164)
        elif is_possible_number(parsed_number):
            # If possible but not valid, still format it
            return format_number(parsed_number, PhoneNumberFormat.E164)
        else:
            return None
    except NumberParseException:
        return None


def validate_phone_number(phone_number: str, default_region: str = "US") -> bool:
    """
    Validate if a phone number is valid.

    Args:
        phone_number: Phone number string to validate
        default_region: Default region code if number doesn't have country code (default: 'US')

    Returns:
        True if phone number is valid, False otherwise
    """
    if not phone_number:
        return False

    formatted = format_phone_number(phone_number, default_region)
    return formatted is not None


def normalize_phone_number(phone_number: str, default_region: str = "US") -> str | None:
    """
    Normalize phone number to E.164 format (alias for format_phone_number for clarity).

    Args:
        phone_number: Phone number string
        default_region: Default region code

    Returns:
        Normalized phone number in E.164 format or None if invalid
    """
    return format_phone_number(phone_number, default_region)


def get_time_until_meeting(meeting_start: datetime) -> timedelta:
    """
    Calculate time remaining until meeting starts.

    Args:
        meeting_start: Meeting start time

    Returns:
        Time delta until meeting (negative if meeting has passed)
    """
    return meeting_start - timezone.now()


def get_time_since_meeting(meeting_end: datetime) -> timedelta:
    """
    Calculate time elapsed since meeting ended.

    Args:
        meeting_end: Meeting end time

    Returns:
        Time delta since meeting (negative if meeting hasn't ended yet)
    """
    return timezone.now() - meeting_end


def format_duration(minutes: int) -> str:
    """
    Format duration in minutes to human-readable string.

    Args:
        minutes: Duration in minutes

    Returns:
        Formatted string (e.g., "1 hour 30 minutes", "45 minutes")
    """
    if minutes < 60:
        return f"{minutes} minute{'s' if minutes != 1 else ''}"

    hours = minutes // 60
    remaining_minutes = minutes % 60

    if remaining_minutes == 0:
        return f"{hours} hour{'s' if hours != 1 else ''}"
    else:
        return f"{hours} hour{'s' if hours != 1 else ''} {remaining_minutes} minute{'s' if remaining_minutes != 1 else ''}"


def parse_datetime_string(datetime_str: str) -> datetime | None:
    """
    Parse datetime string to timezone-aware datetime object.
    Handles various formats including ISO format.

    Args:
        datetime_str: Datetime string to parse

    Returns:
        Timezone-aware datetime object or None if parsing fails
    """
    if not datetime_str:
        return None

    try:
        # Try ISO format first
        dt = datetime.fromisoformat(datetime_str.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = timezone.make_aware(dt)
        return dt
    except ValueError:
        # Try common formats
        formats = [
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%d %H:%M",
            "%m/%d/%Y %H:%M:%S",
            "%m/%d/%Y %H:%M",
        ]
        for fmt in formats:
            try:
                dt = datetime.strptime(datetime_str, fmt)
                return timezone.make_aware(dt)
            except ValueError:
                continue

    return None


def convert_to_utc(dt: datetime) -> datetime:
    """
    Explicitly convert datetime to UTC.

    Args:
        dt: Datetime object (timezone-aware or naive)

    Returns:
        UTC timezone-aware datetime
    """
    if dt.tzinfo is None:
        dt = timezone.make_aware(dt)
    return dt.astimezone(timezone.utc)


# ============================================================================
# Ngrok URL Detection Utilities
# ============================================================================


def get_ngrok_url(api_url: str = "http://localhost:4040/api/tunnels") -> str | None:
    """
    Query ngrok local API to get current tunnel URL.

    Args:
        api_url: Ngrok API endpoint (default: http://localhost:4040/api/tunnels)

    Returns:
        Public ngrok URL (https://...) or None if ngrok is not running or no tunnel found
    """
    try:
        import requests

        response = requests.get(api_url, timeout=2)

        if response.status_code == 200:
            data = response.json()

            # Ngrok API returns: {"tunnels": [{"public_url": "https://...", ...}, ...]}
            tunnels = data.get("tunnels", [])

            if tunnels:
                # Get the first HTTP/HTTPS tunnel (prefer HTTPS)
                for tunnel in tunnels:
                    public_url = tunnel.get("public_url", "")
                    if public_url.startswith("https://"):
                        return public_url.rstrip("/")

                # If no HTTPS, get first HTTP tunnel
                for tunnel in tunnels:
                    public_url = tunnel.get("public_url", "")
                    if public_url.startswith("http://"):
                        return public_url.rstrip("/")

        return None

    except requests.exceptions.ConnectionError:
        # Ngrok is not running
        return None
    except requests.exceptions.Timeout:
        # Ngrok API not responding
        return None
    except Exception as e:
        # Any other error
        import logging

        logger = logging.getLogger(__name__)
        logger.warning(f"Error querying ngrok API: {e}")
        return None


def validate_ngrok_url(url: str) -> bool:
    """
    Validate if a URL is a valid ngrok URL.

    Args:
        url: URL string to validate

    Returns:
        True if URL appears to be a valid ngrok URL, False otherwise
    """
    if not url:
        return False

    # Check for common ngrok domain patterns
    ngrok_patterns = [
        ".ngrok-free.dev",
        ".ngrok.io",
        ".ngrok.app",
        ".ngrok-free.app",
    ]

    url_lower = url.lower()
    return any(pattern in url_lower for pattern in ngrok_patterns)


def build_webhook_url(base_url: str, webhook_path: str = "/webhooks/elevenlabs/") -> str:
    """
    Build full webhook URL from base URL.

    Args:
        base_url: Base URL (e.g., https://abc123.ngrok.io or http://localhost:8000)
        webhook_path: Webhook path (default: /webhooks/elevenlabs/)

    Returns:
        Full webhook URL
    """
    if not base_url:
        return ""

    # Remove trailing slash from base_url
    base_url = base_url.rstrip("/")

    # Ensure webhook_path starts with /
    if not webhook_path.startswith("/"):
        webhook_path = "/" + webhook_path

    return f"{base_url}{webhook_path}"
