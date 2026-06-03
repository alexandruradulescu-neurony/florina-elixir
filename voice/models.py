"""
Data models for the voice app.
"""

from django.contrib.auth.models import AbstractUser
from django.db import models
from django.utils.translation import gettext_lazy as _

from .constants import CallPhase, CallStatus, ClientStatus, LogLevel, VisitStatus
from .encryption import EncryptedTextField


class User(AbstractUser):
    """Custom user model extending Django's AbstractUser."""

    pipedrive_user_id = models.IntegerField(
        null=True, blank=True, help_text="Pipedrive user ID for CRM sync"
    )
    phone_number = models.CharField(
        max_length=20,
        blank=True,
        null=True,
        help_text="Phone number in E.164 format (e.g., +1234567890)",
    )
    is_sales_agent = models.BooleanField(
        default=False, help_text="Designates whether this user is a sales agent who receives calls"
    )
    default_methodology = models.ForeignKey(
        "Methodology",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="assigned_agents",
        help_text="Default meeting preparation methodology for this agent",
    )

    class Meta:
        verbose_name = _("User")
        verbose_name_plural = _("Users")

    def __str__(self):
        return self.username


class VoicePrompt(models.Model):
    """Editable System Prompts for the AI Agent."""

    name = models.CharField(max_length=100, help_text="Descriptive name for this prompt")
    system_prompt = models.TextField(help_text="Instructions for ElevenLabs Agent")
    first_message = models.TextField(
        blank=True,
        null=True,
        help_text="First message/greeting for the AI agent (optional). Supports same variables as system prompt.",
    )
    prompt_type = models.CharField(
        max_length=20, choices=CallPhase.choices, default=CallPhase.PRE_MEETING
    )
    is_active = models.BooleanField(
        default=True, help_text="Only one active prompt per type is allowed"
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Voice Prompt")
        verbose_name_plural = _("Voice Prompts")
        constraints = [
            models.UniqueConstraint(
                fields=["prompt_type"],
                condition=models.Q(is_active=True),
                name="unique_active_prompt",
            )
        ]
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.name} ({self.get_prompt_type_display()})"


class Meeting(models.Model):
    """The Trigger Event - represents a meeting from Google Calendar or Pipedrive."""

    agent = models.ForeignKey(
        User,
        on_delete=models.CASCADE,
        related_name="meetings",
        help_text="Sales agent associated with this meeting",
    )
    external_id = models.CharField(
        max_length=100, unique=True, help_text="External ID from Google Calendar or Pipedrive"
    )
    title = models.CharField(max_length=255, help_text="Meeting title")
    customer_name = models.CharField(
        max_length=255, blank=True, help_text="Name of the customer/client"
    )
    attendees = models.JSONField(
        default=list, blank=True, help_text="List of attendee emails from Google Calendar"
    )
    start_time = models.DateTimeField(help_text="Meeting start time")
    end_time = models.DateTimeField(help_text="Meeting end time")

    # State tracking to prevent duplicate successful calls
    is_pre_call_completed = models.BooleanField(
        default=False, help_text="True if pre-meeting call was successfully completed"
    )
    is_post_call_completed = models.BooleanField(
        default=False, help_text="True if post-meeting call was successfully completed"
    )

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Meeting")
        verbose_name_plural = _("Meetings")
        ordering = ["-start_time"]
        indexes = [
            models.Index(fields=["start_time"]),
            models.Index(fields=["end_time"]),
            models.Index(fields=["external_id"]),
        ]

    def __str__(self):
        return f"{self.title} - {self.agent.username} ({self.start_time})"


class CallAttempt(models.Model):
    """Individual Call Records - tracks each call attempt."""

    meeting = models.ForeignKey(
        Meeting,
        on_delete=models.CASCADE,
        related_name="call_attempts",
        null=True,
        blank=True,
        help_text="Meeting this call is associated with (legacy)",
    )
    visit = models.ForeignKey(
        "Visit",
        on_delete=models.CASCADE,
        related_name="call_attempts",
        null=True,
        blank=True,
        help_text="Visit this call is associated with",
    )
    phase = models.CharField(
        max_length=20, choices=CallPhase.choices, help_text="Pre-meeting or post-meeting call"
    )
    scheduled_offset_minutes = models.IntegerField(
        help_text="Offset in minutes from meeting time (e.g., -60, -30, 15, 30)"
    )

    external_call_id = models.CharField(
        max_length=100,
        blank=True,
        null=True,
        help_text="External call ID from ElevenLabs (may include Twilio SID)",
    )
    status = models.CharField(
        max_length=20, choices=CallStatus.choices, default=CallStatus.SCHEDULED
    )

    recording_url = models.URLField(blank=True, null=True, help_text="URL to the call recording")
    transcript = models.TextField(
        blank=True, null=True, help_text="Transcript of the call conversation"
    )
    summary = models.TextField(
        blank=True,
        null=True,
        help_text="AI-generated summary of the call conversation from ElevenLabs",
    )
    summary_title = models.CharField(
        max_length=255, blank=True, null=True, help_text="Title of the call summary from ElevenLabs"
    )
    analysis = models.JSONField(
        default=dict,
        blank=True,
        help_text="Structured analysis of the call transcript, produced by Claude after a post-call.",
    )

    scheduled_time = models.DateTimeField(
        null=True,
        blank=True,
        help_text="Calculated time when this call should be executed (meeting.start_time + offset for PRE, meeting.end_time + offset for POST)",
    )
    executed_at = models.DateTimeField(
        null=True, blank=True, help_text="When the call was actually executed"
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Call Attempt")
        verbose_name_plural = _("Call Attempts")
        ordering = ["-created_at"]
        indexes = [
            models.Index(fields=["meeting", "phase"]),
            models.Index(fields=["status"]),
            models.Index(fields=["external_call_id"]),
            models.Index(
                fields=["scheduled_time", "status"], name="voice_calla_schedul_status_idx"
            ),
        ]

    def __str__(self):
        if self.visit:
            target = self.visit.title
        elif self.meeting:
            target = self.meeting.title
        else:
            target = "unknown"
        return f"{self.get_phase_display()} call for {target} - {self.get_status_display()}"


class GoogleCalendarWatch(models.Model):
    """Tracks Google Calendar push notification watch channels."""

    user = models.ForeignKey(
        User,
        on_delete=models.CASCADE,
        related_name="calendar_watches",
        help_text="User whose calendar is being watched",
    )
    channel_id = models.CharField(
        max_length=255,
        unique=True,
        help_text="Google Calendar channel ID (unique identifier for this watch)",
    )
    resource_id = models.CharField(
        max_length=255, help_text="Google Calendar resource ID (calendar identifier)"
    )
    expiration = models.DateTimeField(
        help_text="When this watch channel expires (Google sends expiration notifications)"
    )
    token = models.CharField(
        max_length=64,
        blank=True,
        default="",
        help_text="Random per-watch secret. Inbound webhooks must present a matching "
        "X-Goog-Channel-Token; requests that don't match are rejected.",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = _("Google Calendar Watch")
        verbose_name_plural = _("Google Calendar Watches")
        indexes = [
            models.Index(fields=["user"]),
            models.Index(fields=["channel_id"]),
            models.Index(fields=["expiration"]),
        ]

    def __str__(self):
        return f"Watch {self.channel_id} for {self.user.username} (expires {self.expiration})"


class ActivityLog(models.Model):
    """Immutable Audit Log - tracks all system actions."""

    meeting = models.ForeignKey(
        Meeting,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="activity_logs",
        help_text="Associated meeting (if applicable)",
    )
    user = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="activity_logs",
        help_text="User who triggered the action (if applicable)",
    )
    action = models.CharField(max_length=100, help_text="Description of the action performed")
    details = models.JSONField(
        default=dict, blank=True, help_text="Additional details about the action"
    )
    level = models.CharField(max_length=10, choices=LogLevel.choices, default=LogLevel.INFO)
    timestamp = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = _("Activity Log")
        verbose_name_plural = _("Activity Logs")
        ordering = ["-timestamp"]
        indexes = [
            models.Index(fields=["timestamp"]),
            models.Index(fields=["level"]),
            models.Index(fields=["meeting"]),
            models.Index(fields=["user"]),
        ]

    def __str__(self):
        return f"{self.level}: {self.action} at {self.timestamp}"


class Client(models.Model):
    """Client/company synced from CRM. Local copy for AI enrichment and fast access."""

    crm_id = models.CharField(
        max_length=100,
        unique=True,
        help_text="ID in external CRM (e.g., Pipedrive organization ID)",
    )
    name = models.CharField(max_length=255, help_text="Company/organization name")
    domain = models.CharField(
        max_length=255,
        blank=True,
        null=True,
        db_index=True,
        help_text="Email domain for matching calendar attendees (e.g., acme.com)",
    )
    industry = models.CharField(max_length=255, blank=True, null=True)
    status = models.CharField(
        max_length=20,
        choices=ClientStatus.choices,
        default=ClientStatus.NEW,
        db_index=True,
        help_text="Whether this is a new client (no prior history) or existing (prior orders/visits).",
    )
    contacts = models.JSONField(default=list, blank=True, help_text="Key contact persons from CRM")
    deal_history = models.JSONField(
        default=list, blank=True, help_text="Past and current deals summary"
    )
    interaction_history = models.JSONField(
        default=list, blank=True, help_text="Notes, activities, past call summaries from CRM"
    )
    ai_summary = models.TextField(
        blank=True, null=True, help_text="LLM-generated client profile summary"
    )
    raw_data = models.JSONField(default=dict, blank=True, help_text="Full CRM data for reference")
    last_synced_at = models.DateTimeField(
        null=True, blank=True, help_text="Last time this client was synced from CRM"
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Client")
        verbose_name_plural = _("Clients")
        ordering = ["name"]
        indexes = [
            models.Index(fields=["domain"]),
            models.Index(fields=["name"]),
        ]

    def __str__(self):
        return self.name


class Methodology(models.Model):
    """Meeting preparation methodology (e.g., SPIN Selling, MEDDIC, Challenger)."""

    name = models.CharField(max_length=255, help_text="Methodology name")
    description = models.TextField(
        blank=True, null=True, help_text="Short description of the methodology"
    )
    source_material = models.FileField(
        upload_to="methodologies/",
        blank=True,
        null=True,
        help_text="Uploaded PDF with methodology guide",
    )
    ai_summary = models.TextField(
        blank=True,
        null=True,
        help_text="LLM-processed summary of the methodology, editable by manager",
    )
    is_active = models.BooleanField(default=True)
    created_by = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="created_methodologies",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Methodology")
        verbose_name_plural = _("Methodologies")
        ordering = ["name"]

    def __str__(self):
        return self.name


class Visit(models.Model):
    """Central entity tying together agent, client, calendar event, calls, and CRM deal."""

    agent = models.ForeignKey(
        User,
        on_delete=models.CASCADE,
        related_name="visits",
        help_text="Sales agent for this visit",
    )
    client = models.ForeignKey(
        Client, on_delete=models.CASCADE, related_name="visits", help_text="Client being visited"
    )
    calendar_event_id = models.CharField(
        max_length=255, blank=True, null=True, help_text="External calendar event ID"
    )
    title = models.CharField(max_length=255)
    start_time = models.DateTimeField()
    end_time = models.DateTimeField()
    attendees = models.JSONField(
        default=list, blank=True, help_text="Attendee emails from calendar event"
    )
    crm_deal_id = models.CharField(
        max_length=100, blank=True, null=True, help_text="Linked CRM deal ID"
    )
    manager_notes = models.TextField(
        blank=True, null=True, help_text="Free-text notes from manager for pre-call preparation"
    )
    methodology = models.ForeignKey(
        Methodology,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="visits",
        help_text="Override methodology; falls back to agent default then system default",
    )
    status = models.CharField(
        max_length=20,
        choices=VisitStatus.choices,
        default=VisitStatus.PLANNED,
    )
    pre_call_prompt = models.TextField(
        blank=True, null=True, help_text="LLM-generated prompt used for the pre-call"
    )
    pre_call_first_message = models.TextField(
        blank=True,
        default="",
        help_text="First message the AI says on the pre-call (override). Sent verbatim to ElevenLabs.",
    )
    post_call_prompt = models.TextField(
        blank=True, null=True, help_text="LLM-generated prompt used for the post-call"
    )
    post_call_first_message = models.TextField(
        blank=True,
        default="",
        help_text="First message the AI says on the post-call (override). Sent verbatim to ElevenLabs.",
    )
    post_call_summary = models.TextField(
        blank=True, null=True, help_text="Structured debrief summary from post-call"
    )
    crm_synced = models.BooleanField(
        default=False, help_text="Whether the post-call summary was posted to CRM"
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Visit")
        verbose_name_plural = _("Visits")
        ordering = ["-start_time"]
        indexes = [
            models.Index(fields=["start_time"]),
            models.Index(fields=["end_time"]),
            models.Index(fields=["status"]),
            models.Index(fields=["calendar_event_id"]),
            models.Index(fields=["agent", "start_time"]),
        ]

    def __str__(self):
        return f"{self.title} - {self.agent.username} @ {self.client.name} ({self.start_time})"

    def get_effective_methodology(self):
        """Return methodology: visit override > agent default > system default."""
        if self.methodology:
            return self.methodology
        if self.agent.default_methodology:
            return self.agent.default_methodology
        # System default from GlobalSettings
        try:
            settings = GlobalSettings.load()
            return settings.default_methodology
        except GlobalSettings.DoesNotExist:
            return None


class GlobalSettings(models.Model):
    """Singleton model for system-wide configuration."""

    pre_call_offset_minutes = models.IntegerField(
        default=-60, help_text="Minutes before meeting to trigger pre-call (negative value)"
    )
    post_call_offset_minutes = models.IntegerField(
        default=15, help_text="Minutes after meeting to trigger post-call"
    )
    retry_interval_minutes = models.IntegerField(
        default=5, help_text="Minutes between retry attempts for failed calls"
    )
    pre_call_meta_prompt = models.TextField(
        blank=True,
        null=True,
        help_text="Meta-prompt template for generating pre-call voice prompts via LLM",
    )
    post_call_meta_prompt = models.TextField(
        blank=True,
        null=True,
        help_text="Meta-prompt template for generating post-call voice prompts via LLM",
    )
    default_methodology = models.ForeignKey(
        Methodology,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="+",
        help_text="System-wide fallback methodology",
    )
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Global Settings")
        verbose_name_plural = _("Global Settings")

    def __str__(self):
        return "Global Settings"

    @classmethod
    def load(cls):
        """Load the singleton settings instance, creating it if needed."""
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj

    def save(self, *args, **kwargs):
        self.pk = 1
        super().save(*args, **kwargs)


class GoogleOauthCredential(models.Model):
    """Stores Google OAuth credentials for users to enable background calendar sync."""

    user = models.OneToOneField(
        User,
        on_delete=models.CASCADE,
        related_name="google_credentials",
        help_text="User who owns these credentials",
    )
    token = EncryptedTextField(help_text="OAuth access token (encrypted at rest)")
    refresh_token = EncryptedTextField(help_text="OAuth refresh token (encrypted at rest)")
    token_uri = models.URLField(default="https://oauth2.googleapis.com/token")
    client_id = models.CharField(max_length=255)
    client_secret = EncryptedTextField(help_text="OAuth client secret (encrypted at rest)")
    scopes = models.JSONField(default=list, help_text="List of OAuth scopes granted")
    expires_at = models.DateTimeField(null=True, blank=True, help_text="Token expiration time")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Google OAuth Credential")
        verbose_name_plural = _("Google OAuth Credentials")
        indexes = [
            models.Index(fields=["user"]),
        ]

    def __str__(self):
        return f"Google credentials for {self.user.username}"


class MegaPrompt(models.Model):
    """Versioned, single-active-per-domain meta-prompt used by the Auto Prompt Assembler.

    Edit always creates a new version (never in-place). Activating a version
    atomically deactivates any other active version in the same domain.
    Old versions are retained forever; rollback = activating an older row.
    """

    class Domain(models.TextChoices):
        PRE_CALL = "PRE_CALL", _("Pre-call")
        POST_CALL = "POST_CALL", _("Post-call")
        LESSONS_DISTILL = "LESSONS_DISTILL", _("Lessons distill")

    domain = models.CharField(
        max_length=20,
        choices=Domain.choices,
        db_index=True,
        help_text="Which assembler domain this template drives",
    )
    name = models.CharField(max_length=255, help_text="Human label for this version")
    meta_prompt = models.TextField(
        help_text="Instructions sent to Claude. Supports {placeholders} — see spec §4.6."
    )
    is_active = models.BooleanField(
        default=False,
        db_index=True,
        help_text="Only one active version per domain at a time",
    )
    version = models.PositiveIntegerField(default=1)
    created_by = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="created_mega_prompts",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Mega Prompt")
        verbose_name_plural = _("Mega Prompts")
        ordering = ["domain", "-version"]
        constraints = [
            models.UniqueConstraint(
                fields=["domain", "version"],
                name="megaprompt_unique_domain_version",
            ),
        ]

    def __str__(self) -> str:
        marker = " ✓" if self.is_active else ""
        return f"[{self.get_domain_display()}] {self.name} v{self.version}{marker}"
