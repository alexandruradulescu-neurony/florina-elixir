"""
Constants for magic numbers and configuration values.
"""

from django.db import models


class CallStatus(models.TextChoices):
    """Status of a call attempt."""

    SCHEDULED = "SCHEDULED", "Scheduled"
    INITIATED = "INITIATED", "Initiated (Dialing)"
    IN_PROGRESS = "IN_PROGRESS", "In Progress"
    COMPLETED = "COMPLETED", "Completed (Answered)"
    NO_ANSWER = "NO_ANSWER", "No Answer / Busy"
    FAILED = "FAILED", "System Failed"


class CallPhase(models.TextChoices):
    """Phase of the call (pre or post meeting)."""

    PRE_MEETING = "PRE", "Pre-Meeting Training"
    POST_MEETING = "POST", "Post-Meeting Debrief"


class VisitStatus(models.TextChoices):
    """Status of a visit through its lifecycle."""

    PLANNED = "PLANNED", "Planned"
    PRE_CALL_DONE = "PRE_CALL_DONE", "Pre-Call Done"
    IN_PROGRESS = "IN_PROGRESS", "In Progress"
    POST_CALL_DONE = "POST_CALL_DONE", "Post-Call Done"
    COMPLETE = "COMPLETE", "Complete"


class ClientStatus(models.TextChoices):
    """Whether this client is new (no prior history) or existing (prior orders/visits)."""

    NEW = "nou", "Client nou"
    EXISTING = "existent", "Client existent"


# Timing constants (in minutes)
PRE_MEETING_OFFSETS = [-60, -30]  # 1 hour before, 30 mins before
POST_MEETING_OFFSETS = [15, 30]  # 15 mins after, 30 mins after

# Scheduler check window (in minutes) - allows for 5-minute Celery interval
SCHEDULER_WINDOW = 10  # Check within ±5 minutes of target time

# Retry configuration
# Hard cap on total CallAttempt rows per (visit OR meeting, phase). The
# scheduler refuses to create or retry a CallAttempt once this count is
# reached. PR 6: prior to this cap the retry loop in `check_and_trigger_calls`
# ran every 5 minutes against any FAILED/NO_ANSWER call until the meeting
# started — easily producing 50+ outbound dials per night. User explicitly
# asked for "hard cap of two calls" per phase.
MAX_CALL_ATTEMPTS_PER_PHASE = 2
# Legacy alias kept for back-compat (was unreferenced; treated as the same cap now).
MAX_RETRY_ATTEMPTS = MAX_CALL_ATTEMPTS_PER_PHASE
RETRY_DELAY_SECONDS = 60  # Wait 1 minute between retries


# Activity log levels
class LogLevel(models.TextChoices):
    """Logging levels for activity logs."""

    DEBUG = "DEBUG", "Debug"
    INFO = "INFO", "Info"
    WARNING = "WARNING", "Warning"
    ERROR = "ERROR", "Error"
    CRITICAL = "CRITICAL", "Critical"
