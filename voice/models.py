"""
Data models for the voice app.
"""
from django.db import models
from django.contrib.auth.models import AbstractUser
from django.utils.translation import gettext_lazy as _
from .constants import CallStatus, CallPhase, LogLevel


class User(AbstractUser):
    """Custom user model extending Django's AbstractUser."""
    pipedrive_user_id = models.IntegerField(null=True, blank=True, help_text="Pipedrive user ID for CRM sync")
    phone_number = models.CharField(
        max_length=20, 
        blank=True, 
        null=True, 
        help_text="Phone number in E.164 format (e.g., +1234567890)"
    )
    is_sales_agent = models.BooleanField(
        default=False,
        help_text="Designates whether this user is a sales agent who receives calls"
    )

    class Meta:
        verbose_name = _('User')
        verbose_name_plural = _('Users')
    
    def __str__(self):
        return self.username


class VoicePrompt(models.Model):
    """Editable System Prompts for the AI Agent."""
    name = models.CharField(max_length=100, help_text="Descriptive name for this prompt")
    system_prompt = models.TextField(help_text="Instructions for ElevenLabs Agent")
    first_message = models.TextField(
        blank=True,
        null=True,
        help_text="First message/greeting for the AI agent (optional). Supports same variables as system prompt."
    )
    prompt_type = models.CharField(
        max_length=20, 
        choices=CallPhase.choices, 
        default=CallPhase.PRE_MEETING
    )
    is_active = models.BooleanField(
        default=True,
        help_text="Only one active prompt per type is allowed"
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _('Voice Prompt')
        verbose_name_plural = _('Voice Prompts')
        constraints = [
            models.UniqueConstraint(
                fields=['prompt_type'],
                condition=models.Q(is_active=True),
                name='unique_active_prompt'
            )
        ]
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.name} ({self.get_prompt_type_display()})"


class Meeting(models.Model):
    """The Trigger Event - represents a meeting from Google Calendar or Pipedrive."""
    agent = models.ForeignKey(
        User, 
        on_delete=models.CASCADE, 
        related_name='meetings',
        help_text="Sales agent associated with this meeting"
    )
    external_id = models.CharField(
        max_length=100, 
        unique=True, 
        help_text="External ID from Google Calendar or Pipedrive"
    )
    title = models.CharField(max_length=255, help_text="Meeting title")
    customer_name = models.CharField(
        max_length=255, 
        blank=True,
        help_text="Name of the customer/client"
    )
    attendees = models.JSONField(
        default=list,
        blank=True,
        help_text="List of attendee emails from Google Calendar"
    )
    start_time = models.DateTimeField(help_text="Meeting start time")
    end_time = models.DateTimeField(help_text="Meeting end time")
    
    # State tracking to prevent duplicate successful calls
    is_pre_call_completed = models.BooleanField(
        default=False,
        help_text="True if pre-meeting call was successfully completed"
    )
    is_post_call_completed = models.BooleanField(
        default=False,
        help_text="True if post-meeting call was successfully completed"
    )
    
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _('Meeting')
        verbose_name_plural = _('Meetings')
        ordering = ['-start_time']
        indexes = [
            models.Index(fields=['start_time']),
            models.Index(fields=['end_time']),
            models.Index(fields=['external_id']),
        ]

    def __str__(self):
        return f"{self.title} - {self.agent.username} ({self.start_time})"


class CallAttempt(models.Model):
    """Individual Call Records - tracks each call attempt."""
    meeting = models.ForeignKey(
        Meeting, 
        on_delete=models.CASCADE, 
        related_name='call_attempts',
        help_text="Meeting this call is associated with"
    )
    phase = models.CharField(
        max_length=20, 
        choices=CallPhase.choices,
        help_text="Pre-meeting or post-meeting call"
    )
    scheduled_offset_minutes = models.IntegerField(
        help_text="Offset in minutes from meeting time (e.g., -60, -30, 15, 30)"
    )
    
    external_call_id = models.CharField(
        max_length=100, 
        blank=True, 
        null=True,
        help_text="External call ID from ElevenLabs (may include Twilio SID)"
    )
    status = models.CharField(
        max_length=20, 
        choices=CallStatus.choices, 
        default=CallStatus.SCHEDULED
    )
    
    recording_url = models.URLField(
        blank=True, 
        null=True,
        help_text="URL to the call recording"
    )
    transcript = models.TextField(
        blank=True, 
        null=True,
        help_text="Transcript of the call conversation"
    )
    summary = models.TextField(
        blank=True,
        null=True,
        help_text="AI-generated summary of the call conversation from ElevenLabs"
    )
    summary_title = models.CharField(
        max_length=255,
        blank=True,
        null=True,
        help_text="Title of the call summary from ElevenLabs"
    )
    
    scheduled_time = models.DateTimeField(
        null=True,
        blank=True,
        help_text="Calculated time when this call should be executed (meeting.start_time + offset for PRE, meeting.end_time + offset for POST)"
    )
    executed_at = models.DateTimeField(
        null=True, 
        blank=True,
        help_text="When the call was actually executed"
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _('Call Attempt')
        verbose_name_plural = _('Call Attempts')
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['meeting', 'phase']),
            models.Index(fields=['status']),
            models.Index(fields=['external_call_id']),
            models.Index(fields=['scheduled_time', 'status'], name='voice_calla_schedul_status_idx'),
        ]

    def __str__(self):
        return f"{self.get_phase_display()} call for {self.meeting.title} - {self.get_status_display()}"


class GoogleCalendarWatch(models.Model):
    """Tracks Google Calendar push notification watch channels."""
    user = models.ForeignKey(
        User,
        on_delete=models.CASCADE,
        related_name='calendar_watches',
        help_text="User whose calendar is being watched"
    )
    channel_id = models.CharField(
        max_length=255,
        unique=True,
        help_text="Google Calendar channel ID (unique identifier for this watch)"
    )
    resource_id = models.CharField(
        max_length=255,
        help_text="Google Calendar resource ID (calendar identifier)"
    )
    expiration = models.DateTimeField(
        help_text="When this watch channel expires (Google sends expiration notifications)"
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = _('Google Calendar Watch')
        verbose_name_plural = _('Google Calendar Watches')
        indexes = [
            models.Index(fields=['user']),
            models.Index(fields=['channel_id']),
            models.Index(fields=['expiration']),
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
        related_name='activity_logs',
        help_text="Associated meeting (if applicable)"
    )
    user = models.ForeignKey(
        User, 
        on_delete=models.SET_NULL, 
        null=True, 
        blank=True,
        related_name='activity_logs',
        help_text="User who triggered the action (if applicable)"
    )
    action = models.CharField(
        max_length=100,
        help_text="Description of the action performed"
    )
    details = models.JSONField(
        default=dict, 
        blank=True,
        help_text="Additional details about the action"
    )
    level = models.CharField(
        max_length=10, 
        choices=LogLevel.choices,
        default=LogLevel.INFO
    )
    timestamp = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = _('Activity Log')
        verbose_name_plural = _('Activity Logs')
        ordering = ['-timestamp']
        indexes = [
            models.Index(fields=['timestamp']),
            models.Index(fields=['level']),
            models.Index(fields=['meeting']),
            models.Index(fields=['user']),
        ]

    def __str__(self):
        return f"{self.level}: {self.action} at {self.timestamp}"


class GoogleOauthCredential(models.Model):
    """Stores Google OAuth credentials for users to enable background calendar sync."""
    user = models.OneToOneField(
        User,
        on_delete=models.CASCADE,
        related_name='google_credentials',
        help_text="User who owns these credentials"
    )
    token = models.TextField(help_text="OAuth access token (encrypted in production)")
    refresh_token = models.TextField(help_text="OAuth refresh token (encrypted in production)")
    token_uri = models.URLField(default='https://oauth2.googleapis.com/token')
    client_id = models.CharField(max_length=255)
    client_secret = models.CharField(max_length=255)
    scopes = models.JSONField(default=list, help_text="List of OAuth scopes granted")
    expires_at = models.DateTimeField(null=True, blank=True, help_text="Token expiration time")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _('Google OAuth Credential')
        verbose_name_plural = _('Google OAuth Credentials')
        indexes = [
            models.Index(fields=['user']),
        ]

    def __str__(self):
        return f"Google credentials for {self.user.username}"
