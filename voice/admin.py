"""
Django admin configuration for the voice app.
"""
from django.contrib import admin
from django.utils.html import format_html
from .models import (
    User, VoicePrompt, Meeting, CallAttempt, ActivityLog,
    GoogleOauthCredential, GoogleCalendarWatch,
    Client, Methodology, Visit, GlobalSettings,
)


@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    """Admin interface for User model."""
    list_display = ['username', 'email', 'is_sales_agent', 'phone_number', 'pipedrive_user_id', 'is_staff', 'is_active']
    list_filter = ['is_sales_agent', 'is_staff', 'is_active', 'is_superuser']
    search_fields = ['username', 'email', 'phone_number']
    fieldsets = (
        (None, {'fields': ('username', 'password')}),
        ('Personal info', {'fields': ('first_name', 'last_name', 'email', 'phone_number')}),
        ('Sales Agent Info', {'fields': ('is_sales_agent', 'pipedrive_user_id', 'default_methodology')}),
        ('Permissions', {'fields': ('is_active', 'is_staff', 'is_superuser', 'groups', 'user_permissions')}),
        ('Important dates', {'fields': ('last_login', 'date_joined')}),
    )


@admin.register(VoicePrompt)
class VoicePromptAdmin(admin.ModelAdmin):
    """Admin interface for VoicePrompt model."""
    list_display = ['name', 'prompt_type', 'is_active', 'created_at', 'updated_at']
    list_filter = ['prompt_type', 'is_active']
    search_fields = ['name', 'system_prompt', 'first_message']
    readonly_fields = ['created_at', 'updated_at']
    
    fieldsets = (
        (None, {'fields': ('name', 'prompt_type', 'is_active')}),
        ('Prompt Content', {'fields': ('system_prompt', 'first_message')}),
        ('Timestamps', {'fields': ('created_at', 'updated_at')}),
    )
    
    def save_model(self, request, obj, form, change):
        """Ensure only one active prompt per type."""
        if obj.is_active:
            # Deactivate other prompts of the same type
            VoicePrompt.objects.filter(
                prompt_type=obj.prompt_type,
                is_active=True
            ).exclude(pk=obj.pk).update(is_active=False)
        super().save_model(request, obj, form, change)


@admin.register(Meeting)
class MeetingAdmin(admin.ModelAdmin):
    """Admin interface for Meeting model."""
    list_display = ['title', 'agent', 'customer_name', 'start_time', 'end_time', 
                    'pre_call_status', 'post_call_status', 'created_at']
    list_filter = ['is_pre_call_completed', 'is_post_call_completed', 'start_time', 'created_at']
    search_fields = ['title', 'customer_name', 'external_id', 'agent__username']
    readonly_fields = ['created_at', 'updated_at']
    date_hierarchy = 'start_time'
    
    fieldsets = (
        ('Meeting Information', {
            'fields': ('agent', 'external_id', 'title', 'customer_name')
        }),
        ('Schedule', {
            'fields': ('start_time', 'end_time')
        }),
        ('Call Status', {
            'fields': ('is_pre_call_completed', 'is_post_call_completed')
        }),
        ('Timestamps', {
            'fields': ('created_at', 'updated_at')
        }),
    )
    
    def pre_call_status(self, obj):
        """Display pre-call status with color."""
        if obj.is_pre_call_completed:
            return format_html('<span style="color: green;">✓ Completed</span>')
        return format_html('<span style="color: orange;">Pending</span>')
    pre_call_status.short_description = 'Pre-Call Status'
    
    def post_call_status(self, obj):
        """Display post-call status with color."""
        if obj.is_post_call_completed:
            return format_html('<span style="color: green;">✓ Completed</span>')
        return format_html('<span style="color: orange;">Pending</span>')
    post_call_status.short_description = 'Post-Call Status'


@admin.register(CallAttempt)
class CallAttemptAdmin(admin.ModelAdmin):
    """Admin interface for CallAttempt model."""
    list_display = ['meeting', 'phase', 'scheduled_offset_minutes', 'status', 
                    'external_call_id', 'executed_at', 'created_at']
    list_filter = ['phase', 'status', 'created_at', 'executed_at']
    search_fields = ['meeting__title', 'external_call_id', 'meeting__agent__username']
    readonly_fields = ['created_at', 'updated_at']
    date_hierarchy = 'created_at'
    
    fieldsets = (
        ('Call Information', {
            'fields': ('meeting', 'visit', 'phase', 'scheduled_offset_minutes', 'status')
        }),
        ('External Integration', {
            'fields': ('external_call_id', 'recording_url')
        }),
        ('Call Results', {
            'fields': ('transcript', 'summary', 'summary_title', 'executed_at')
        }),
        ('Timestamps', {
            'fields': ('created_at', 'updated_at')
        }),
    )


@admin.register(ActivityLog)
class ActivityLogAdmin(admin.ModelAdmin):
    """Admin interface for ActivityLog model."""
    list_display = ['action', 'level', 'meeting', 'user', 'timestamp']
    list_filter = ['level', 'timestamp']
    search_fields = ['action', 'meeting__title', 'user__username']
    readonly_fields = ['timestamp']
    date_hierarchy = 'timestamp'
    
    fieldsets = (
        ('Log Information', {
            'fields': ('action', 'level', 'meeting', 'user')
        }),
        ('Details', {
            'fields': ('details',)
        }),
        ('Timestamp', {
            'fields': ('timestamp',)
        }),
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
    list_display = ['user', 'client_id', 'expires_at', 'created_at', 'updated_at']
    list_filter = ['created_at', 'updated_at']
    search_fields = ['user__username', 'user__email', 'client_id']
    readonly_fields = ['created_at', 'updated_at']
    
    fieldsets = (
        ('User', {'fields': ('user',)}),
        ('OAuth Credentials', {
            'fields': ('token', 'refresh_token', 'token_uri', 'client_id', 'client_secret', 'scopes'),
            'classes': ('collapse',)
        }),
        ('Metadata', {'fields': ('expires_at', 'created_at', 'updated_at')}),
    )
    
    def has_add_permission(self, request):
        """Credentials should only be created via OAuth flow."""
        return False


@admin.register(GoogleCalendarWatch)
class GoogleCalendarWatchAdmin(admin.ModelAdmin):
    """Admin interface for GoogleCalendarWatch model."""
    list_display = ['user', 'channel_id', 'resource_id', 'expiration', 'created_at']
    list_filter = ['expiration', 'created_at']
    search_fields = ['user__username', 'channel_id', 'resource_id']
    readonly_fields = ['created_at']
    
    fieldsets = (
        ('Watch Information', {
            'fields': ('user', 'channel_id', 'resource_id', 'expiration')
        }),
        ('Timestamp', {
            'fields': ('created_at',)
        }),
    )
    
    def has_add_permission(self, request):
        """Watch channels should only be created via API."""
        return False


@admin.register(Client)
class ClientAdmin(admin.ModelAdmin):
    list_display = ['name', 'domain', 'industry', 'crm_id', 'last_synced_at']
    list_filter = ['industry', 'last_synced_at']
    search_fields = ['name', 'domain', 'crm_id']
    readonly_fields = ['created_at', 'updated_at', 'last_synced_at']
    fieldsets = (
        ('Client Info', {'fields': ('name', 'domain', 'industry', 'crm_id')}),
        ('CRM Data', {
            'fields': ('contacts', 'deal_history', 'interaction_history', 'raw_data'),
            'classes': ('collapse',),
        }),
        ('AI', {'fields': ('ai_summary',)}),
        ('Timestamps', {'fields': ('last_synced_at', 'created_at', 'updated_at')}),
    )


@admin.register(Methodology)
class MethodologyAdmin(admin.ModelAdmin):
    list_display = ['name', 'is_active', 'created_by', 'created_at']
    list_filter = ['is_active']
    search_fields = ['name', 'description']
    readonly_fields = ['created_at', 'updated_at']
    fieldsets = (
        (None, {'fields': ('name', 'description', 'is_active', 'created_by')}),
        ('Material', {'fields': ('source_material', 'ai_summary')}),
        ('Timestamps', {'fields': ('created_at', 'updated_at')}),
    )


@admin.register(Visit)
class VisitAdmin(admin.ModelAdmin):
    list_display = ['title', 'agent', 'client', 'start_time', 'status', 'crm_synced']
    list_filter = ['status', 'crm_synced', 'start_time']
    search_fields = ['title', 'agent__username', 'client__name']
    readonly_fields = ['created_at', 'updated_at']
    date_hierarchy = 'start_time'
    fieldsets = (
        ('Visit Info', {
            'fields': ('agent', 'client', 'title', 'calendar_event_id', 'start_time', 'end_time', 'attendees')
        }),
        ('Configuration', {
            'fields': ('methodology', 'manager_notes', 'crm_deal_id', 'status')
        }),
        ('Generated Prompts', {
            'fields': ('pre_call_prompt', 'post_call_prompt'),
            'classes': ('collapse',),
        }),
        ('Results', {
            'fields': ('post_call_summary', 'crm_synced')
        }),
        ('Timestamps', {'fields': ('created_at', 'updated_at')}),
    )


@admin.register(GlobalSettings)
class GlobalSettingsAdmin(admin.ModelAdmin):
    list_display = ['__str__', 'pre_call_offset_minutes', 'post_call_offset_minutes', 'updated_at']
    readonly_fields = ['updated_at']
    fieldsets = (
        ('Call Timing', {
            'fields': ('pre_call_offset_minutes', 'post_call_offset_minutes', 'retry_interval_minutes')
        }),
        ('Meta-Prompts', {
            'fields': ('pre_call_meta_prompt', 'post_call_meta_prompt'),
        }),
        ('Defaults', {'fields': ('default_methodology',)}),
        ('Timestamps', {'fields': ('updated_at',)}),
    )

    def has_add_permission(self, request):
        return not GlobalSettings.objects.exists()

    def has_delete_permission(self, request, obj=None):
        return False
