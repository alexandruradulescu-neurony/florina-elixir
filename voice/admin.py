"""
Django admin configuration for the voice app.
"""

from django.contrib import admin
from django.utils.html import format_html

from .models import (
    ActivityLog,
    CallAttempt,
    Client,
    GenerationRun,
    GlobalSettings,
    GoogleCalendarWatch,
    GoogleOauthCredential,
    Meeting,
    MegaPrompt,
    Methodology,
    Scenario,
    User,
    Visit,
    VoicePrompt,
)


@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    """Admin interface for User model."""

    list_display = [
        "username",
        "email",
        "is_sales_agent",
        "phone_number",
        "pipedrive_user_id",
        "is_staff",
        "is_active",
    ]
    list_filter = ["is_sales_agent", "is_staff", "is_active", "is_superuser"]
    search_fields = ["username", "email", "phone_number"]
    fieldsets = (
        (None, {"fields": ("username", "password")}),
        ("Personal info", {"fields": ("first_name", "last_name", "email", "phone_number")}),
        (
            "Sales Agent Info",
            {"fields": ("is_sales_agent", "pipedrive_user_id", "default_methodology")},
        ),
        (
            "Permissions",
            {"fields": ("is_active", "is_staff", "is_superuser", "groups", "user_permissions")},
        ),
        ("Important dates", {"fields": ("last_login", "date_joined")}),
    )


@admin.register(VoicePrompt)
class VoicePromptAdmin(admin.ModelAdmin):
    """Admin interface for VoicePrompt model."""

    list_display = ["name", "prompt_type", "is_active", "created_at", "updated_at"]
    list_filter = ["prompt_type", "is_active"]
    search_fields = ["name", "system_prompt", "first_message"]
    readonly_fields = ["created_at", "updated_at"]

    fieldsets = (
        (None, {"fields": ("name", "prompt_type", "is_active")}),
        ("Prompt Content", {"fields": ("system_prompt", "first_message")}),
        ("Timestamps", {"fields": ("created_at", "updated_at")}),
    )

    def save_model(self, request, obj, form, change):
        """Ensure only one active prompt per type."""
        if obj.is_active:
            # Deactivate other prompts of the same type
            VoicePrompt.objects.filter(prompt_type=obj.prompt_type, is_active=True).exclude(
                pk=obj.pk
            ).update(is_active=False)
        super().save_model(request, obj, form, change)


@admin.register(Meeting)
class MeetingAdmin(admin.ModelAdmin):
    """Admin interface for Meeting model."""

    list_display = [
        "title",
        "agent",
        "customer_name",
        "start_time",
        "end_time",
        "pre_call_status",
        "post_call_status",
        "created_at",
    ]
    list_filter = ["is_pre_call_completed", "is_post_call_completed", "start_time", "created_at"]
    search_fields = ["title", "customer_name", "external_id", "agent__username"]
    readonly_fields = ["created_at", "updated_at"]
    date_hierarchy = "start_time"

    fieldsets = (
        ("Meeting Information", {"fields": ("agent", "external_id", "title", "customer_name")}),
        ("Schedule", {"fields": ("start_time", "end_time")}),
        ("Call Status", {"fields": ("is_pre_call_completed", "is_post_call_completed")}),
        ("Timestamps", {"fields": ("created_at", "updated_at")}),
    )

    def pre_call_status(self, obj):
        """Display pre-call status with color."""
        if obj.is_pre_call_completed:
            return format_html('<span style="color: green;">✓ Completed</span>')
        return format_html('<span style="color: orange;">Pending</span>')

    pre_call_status.short_description = "Pre-Call Status"

    def post_call_status(self, obj):
        """Display post-call status with color."""
        if obj.is_post_call_completed:
            return format_html('<span style="color: green;">✓ Completed</span>')
        return format_html('<span style="color: orange;">Pending</span>')

    post_call_status.short_description = "Post-Call Status"


@admin.register(CallAttempt)
class CallAttemptAdmin(admin.ModelAdmin):
    """Admin interface for CallAttempt model."""

    list_display = [
        "meeting",
        "phase",
        "scheduled_offset_minutes",
        "status",
        "external_call_id",
        "executed_at",
        "created_at",
    ]
    list_filter = ["phase", "status", "created_at", "executed_at"]
    search_fields = ["meeting__title", "external_call_id", "meeting__agent__username"]
    readonly_fields = ["created_at", "updated_at"]
    date_hierarchy = "created_at"

    fieldsets = (
        (
            "Call Information",
            {"fields": ("meeting", "visit", "phase", "scheduled_offset_minutes", "status")},
        ),
        ("External Integration", {"fields": ("external_call_id", "recording_url")}),
        ("Call Results", {"fields": ("transcript", "summary", "summary_title", "executed_at")}),
        ("Timestamps", {"fields": ("created_at", "updated_at")}),
    )


@admin.register(ActivityLog)
class ActivityLogAdmin(admin.ModelAdmin):
    """Admin interface for ActivityLog model."""

    list_display = ["action", "level", "meeting", "user", "timestamp"]
    list_filter = ["level", "timestamp"]
    search_fields = ["action", "meeting__title", "user__username"]
    readonly_fields = ["timestamp"]
    date_hierarchy = "timestamp"

    fieldsets = (
        ("Log Information", {"fields": ("action", "level", "meeting", "user")}),
        ("Details", {"fields": ("details",)}),
        ("Timestamp", {"fields": ("timestamp",)}),
    )

    def has_add_permission(self, request):
        """Activity logs are immutable - cannot be manually created."""
        return False

    def has_change_permission(self, request, obj=None):
        """Activity logs are immutable - cannot be edited."""
        return False


@admin.register(GoogleOauthCredential)
class GoogleOauthCredentialAdmin(admin.ModelAdmin):
    """Admin interface for GoogleOauthCredential model."""

    list_display = ["user", "client_id", "expires_at", "created_at", "updated_at"]
    list_filter = ["created_at", "updated_at"]
    search_fields = ["user__username", "user__email", "client_id"]
    readonly_fields = ["created_at", "updated_at", "secrets_status"]

    # Sensitive secrets (token, refresh_token, client_secret) are deliberately
    # NOT exposed in the admin form — they are encrypted at rest and must not be
    # readable/editable through the admin UI.
    fieldsets = (
        ("User", {"fields": ("user",)}),
        (
            "OAuth Credentials",
            {
                "fields": ("secrets_status", "token_uri", "client_id", "scopes"),
                "classes": ("collapse",),
            },
        ),
        ("Metadata", {"fields": ("expires_at", "created_at", "updated_at")}),
    )

    @admin.display(description="Secrets (token / refresh / client_secret)")
    def secrets_status(self, obj):
        # Never reads or decrypts the stored values — pure redaction.
        return "•••••••• encrypted at rest — not shown"

    def has_add_permission(self, request):
        """Credentials should only be created via OAuth flow."""
        return False


@admin.register(GoogleCalendarWatch)
class GoogleCalendarWatchAdmin(admin.ModelAdmin):
    """Admin interface for GoogleCalendarWatch model."""

    list_display = ["user", "channel_id", "resource_id", "expiration", "created_at"]
    list_filter = ["expiration", "created_at"]
    search_fields = ["user__username", "channel_id", "resource_id"]
    readonly_fields = ["created_at"]

    fieldsets = (
        ("Watch Information", {"fields": ("user", "channel_id", "resource_id", "expiration")}),
        ("Timestamp", {"fields": ("created_at",)}),
    )

    def has_add_permission(self, request):
        """Watch channels should only be created via API."""
        return False


@admin.register(Client)
class ClientAdmin(admin.ModelAdmin):
    list_display = ["name", "domain", "industry", "crm_id", "last_synced_at"]
    list_filter = ["industry", "last_synced_at"]
    search_fields = ["name", "domain", "crm_id"]
    readonly_fields = ["created_at", "updated_at", "last_synced_at"]
    fieldsets = (
        ("Client Info", {"fields": ("name", "domain", "industry", "crm_id")}),
        (
            "CRM Data",
            {
                "fields": ("contacts", "deal_history", "interaction_history", "raw_data"),
                "classes": ("collapse",),
            },
        ),
        ("AI", {"fields": ("ai_summary",)}),
        ("Timestamps", {"fields": ("last_synced_at", "created_at", "updated_at")}),
    )


@admin.register(Methodology)
class MethodologyAdmin(admin.ModelAdmin):
    list_display = ["name", "is_active", "created_by", "created_at"]
    list_filter = ["is_active"]
    search_fields = ["name", "description"]
    readonly_fields = ["created_at", "updated_at"]
    fieldsets = (
        (None, {"fields": ("name", "description", "is_active", "created_by")}),
        ("Material", {"fields": ("source_material", "ai_summary")}),
        ("Timestamps", {"fields": ("created_at", "updated_at")}),
    )


@admin.register(Visit)
class VisitAdmin(admin.ModelAdmin):
    list_display = ["title", "agent", "client", "start_time", "status", "crm_synced"]
    list_filter = ["status", "crm_synced", "start_time"]
    search_fields = ["title", "agent__username", "client__name"]
    readonly_fields = ["created_at", "updated_at"]
    date_hierarchy = "start_time"
    fieldsets = (
        (
            "Visit Info",
            {
                "fields": (
                    "agent",
                    "client",
                    "title",
                    "calendar_event_id",
                    "start_time",
                    "end_time",
                    "attendees",
                )
            },
        ),
        ("Configuration", {"fields": ("methodology", "manager_notes", "crm_deal_id", "status")}),
        (
            "Generated Prompts",
            {
                "fields": ("pre_call_prompt", "post_call_prompt"),
                "classes": ("collapse",),
            },
        ),
        ("Results", {"fields": ("post_call_summary", "crm_synced")}),
        ("Timestamps", {"fields": ("created_at", "updated_at")}),
    )


@admin.register(GlobalSettings)
class GlobalSettingsAdmin(admin.ModelAdmin):
    list_display = ["__str__", "pre_call_offset_minutes", "post_call_offset_minutes", "updated_at"]
    readonly_fields = ["updated_at"]
    fieldsets = (
        (
            "Call Timing",
            {
                "fields": (
                    "pre_call_offset_minutes",
                    "post_call_offset_minutes",
                    "retry_interval_minutes",
                )
            },
        ),
        (
            "Meta-Prompts",
            {
                "fields": ("pre_call_meta_prompt", "post_call_meta_prompt"),
            },
        ),
        ("Defaults", {"fields": ("default_methodology",)}),
        ("Timestamps", {"fields": ("updated_at",)}),
    )

    def has_add_permission(self, request):
        return not GlobalSettings.objects.exists()

    def has_delete_permission(self, request, obj=None):
        return False


@admin.register(MegaPrompt)
class MegaPromptAdmin(admin.ModelAdmin):
    list_display = ("domain", "name", "version", "is_active", "updated_at")
    list_filter = ("domain", "is_active")
    search_fields = ("name", "meta_prompt")
    ordering = ("domain", "-version")

    # Spec §7: "Edit always creates a new version (never in-place)."
    # `is_active` is never directly editable via the form — use the
    # "Activate this version" admin action below, which atomically deactivates
    # any sibling active version in the same domain. New rows always land
    # inactive (forced in `save_model`); to switch the live version, the admin
    # selects exactly one row and runs the action.
    actions = ["make_active_atomically"]

    def get_readonly_fields(self, request, obj=None):
        base = ["version", "created_at", "updated_at", "created_by", "is_active"]
        # An active version is immutable via this form — mutating its text
        # would silently change what historical GenerationRun rows reference.
        if obj is not None and obj.is_active:
            base += ["domain", "name", "meta_prompt"]
        return base

    def save_model(self, request, obj, form, change):
        if not change:
            # A new MegaPrompt always lands inactive. Use the action to
            # promote it to active (with atomic sibling deactivation).
            obj.is_active = False
            if not obj.created_by_id:
                obj.created_by = request.user
        super().save_model(request, obj, form, change)

    def has_delete_permission(self, request, obj=None):
        # App-layer guard (spec §7): never delete the currently active version
        # of any domain. The DB partial-unique constraint on (domain) WHERE
        # is_active also makes silent deletion safer downstream.
        if obj is not None and obj.is_active:
            return False
        return super().has_delete_permission(request, obj)

    def get_actions(self, request):
        # Remove the bulk "delete selected" action so a careless admin can't wipe
        # multiple versions (including active ones) in one click.
        actions = super().get_actions(request)
        actions.pop("delete_selected", None)
        return actions

    @admin.action(description="Activate this version (deactivates sibling in same domain)")
    def make_active_atomically(self, request, queryset):
        from django.db import transaction

        if queryset.count() != 1:
            self.message_user(
                request,
                "Select exactly ONE MegaPrompt to activate.",
                level="error",
            )
            return
        with transaction.atomic():
            target = queryset.select_for_update().get()
            if target.is_active:
                self.message_user(
                    request,
                    f"[{target.get_domain_display()}] v{target.version} is already active.",
                )
                return
            MegaPrompt.objects.filter(domain=target.domain, is_active=True).exclude(
                pk=target.pk
            ).update(is_active=False)
            target.is_active = True
            target.save(update_fields=["is_active", "updated_at"])
        self.message_user(
            request,
            f"Activated [{target.get_domain_display()}] v{target.version}; previous active version deactivated.",
        )


@admin.register(Scenario)
class ScenarioAdmin(admin.ModelAdmin):
    list_display = ("name", "slug", "is_active", "updated_at")
    list_filter = ("is_active",)
    search_fields = ("name", "slug", "description")
    prepopulated_fields = {"slug": ("name",)}


@admin.register(GenerationRun)
class GenerationRunAdmin(admin.ModelAdmin):
    # Fields whose stored value is encrypted-at-rest PII (transcripts, manager
    # notes, CRM history, generated voice-prompt text). Encryption-at-rest is
    # only meaningful if the decrypted view is also gated — otherwise any
    # is_staff user (e.g. a sales agent who happens to have admin access) can
    # read everything by clicking through to a single GenerationRun. We restrict
    # the detail view of these columns to is_superuser; non-superuser staff see
    # only the structural fields (domain / triggered_by / counts / success).
    ENCRYPTED_FIELDS = (
        "context_bundle",
        "claude_request",
        "claude_response",
        "parsed_outputs",
        "error",
    )

    list_display = (
        "created_at",
        "domain",
        "visit",
        "client",
        "success",
        "input_tokens",
        "output_tokens",
    )
    list_filter = ("domain", "success", "triggered_by")
    # Ciphertext is unsearchable, so `search_fields` is intentionally empty —
    # filter by the structured columns above.
    ordering = ("-created_at",)

    def get_fields(self, request, obj=None):
        # Concrete columns only (no reverse relations); hide encrypted blobs
        # from non-superuser staff.
        all_fields = [f.name for f in self.model._meta.fields]
        if request.user.is_superuser:
            return all_fields
        return [f for f in all_fields if f not in self.ENCRYPTED_FIELDS]

    def get_readonly_fields(self, request, obj=None):
        # GenerationRun is an immutable audit table — nothing is editable
        # through the admin form, regardless of role.
        return self.get_fields(request, obj)

    def has_add_permission(self, request):
        # Runs are created by the assembler, never by an admin click.
        return False

    def has_change_permission(self, request, obj=None):
        # View only — the form is for inspection. Returning True lets staff
        # open the detail page; the readonly_fields above prevent edits.
        return True

    def has_delete_permission(self, request, obj=None):
        # Audit rows are append-only; only superusers can prune (rare).
        return request.user.is_superuser
