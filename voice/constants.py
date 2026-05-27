"""
Constants for magic numbers and configuration values.
"""

from django.db import models


class CallStatus(models.TextChoices):
    """Status of a call attempt."""
    SCHEDULED = 'SCHEDULED', 'Scheduled'
    INITIATED = 'INITIATED', 'Initiated (Dialing)'
    IN_PROGRESS = 'IN_PROGRESS', 'In Progress'
    COMPLETED = 'COMPLETED', 'Completed (Answered)'
    NO_ANSWER = 'NO_ANSWER', 'No Answer / Busy'
    FAILED = 'FAILED', 'System Failed'


class CallPhase(models.TextChoices):
    """Phase of the call (pre or post meeting)."""
    PRE_MEETING = 'PRE', 'Pre-Meeting Training'
    POST_MEETING = 'POST', 'Post-Meeting Debrief'


class VisitStatus(models.TextChoices):
    """Status of a visit through its lifecycle."""
    PLANNED = 'PLANNED', 'Planned'
    PRE_CALL_DONE = 'PRE_CALL_DONE', 'Pre-Call Done'
    IN_PROGRESS = 'IN_PROGRESS', 'In Progress'
    POST_CALL_DONE = 'POST_CALL_DONE', 'Post-Call Done'
    COMPLETE = 'COMPLETE', 'Complete'


class ClientStatus(models.TextChoices):
    """Whether this client is new (no prior history) or existing (prior orders/visits)."""
    NEW = 'nou', 'Client nou'
    EXISTING = 'existent', 'Client existent'


# Timing constants (in minutes)
PRE_MEETING_OFFSETS = [-60, -30]  # 1 hour before, 30 mins before
POST_MEETING_OFFSETS = [15, 30]   # 15 mins after, 30 mins after

# Scheduler check window (in minutes) - allows for 5-minute Celery interval
SCHEDULER_WINDOW = 10  # Check within ±5 minutes of target time

# Retry configuration
MAX_RETRY_ATTEMPTS = 3
RETRY_DELAY_SECONDS = 60  # Wait 1 minute between retries

# Activity log levels
class LogLevel(models.TextChoices):
    """Logging levels for activity logs."""
    DEBUG = 'DEBUG', 'Debug'
    INFO = 'INFO', 'Info'
    WARNING = 'WARNING', 'Warning'
    ERROR = 'ERROR', 'Error'
    CRITICAL = 'CRITICAL', 'Critical'
