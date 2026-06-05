"""
Activity Logging Service.

Centralized logging for all system actions.

PR Y2b: the `meeting` parameter was removed along with the Meeting model.
Pass `visit=...` instead — `ActivityLog.visit` is the visit-flow audit link.
For callers that don't have a visit (e.g. global / user-level events), just
omit it.
"""

import json
import logging
from typing import Any

from voice.constants import LogLevel
from voice.models import ActivityLog, User, Visit

logger = logging.getLogger(__name__)


def log_activity(
    visit: Visit | None = None,
    user: User | None = None,
    action: str = "",
    details: dict[str, Any] | None = None,
    level: str = LogLevel.INFO,
) -> ActivityLog:
    """
    Centralized logging function for all system actions.

    Args:
        visit: Associated Visit (optional)
        user: User who triggered the action (optional)
        action: Description of the action
        details: Additional details as dictionary
        level: Log level (DEBUG, INFO, WARNING, ERROR, CRITICAL)

    Returns:
        Created ActivityLog instance
    """
    if details is None:
        details = {}

    activity_log = ActivityLog.objects.create(
        visit=visit, user=user, action=action, details=details, level=level
    )

    # Also log to Django's logging system
    log_message = (
        f"{action} | Visit: {visit.id if visit else 'N/A'} "
        f"| User: {user.username if user else 'System'}"
    )
    if details:
        log_message += f" | Details: {json.dumps(details)}"

    if level == LogLevel.DEBUG:
        logger.debug(log_message)
    elif level == LogLevel.INFO:
        logger.info(log_message)
    elif level == LogLevel.WARNING:
        logger.warning(log_message)
    elif level == LogLevel.ERROR:
        logger.error(log_message)
    elif level == LogLevel.CRITICAL:
        logger.critical(log_message)

    return activity_log
