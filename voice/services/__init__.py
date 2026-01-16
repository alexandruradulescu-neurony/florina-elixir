"""
Voice Services Package.

This package contains business logic services for the voice app,
organized into focused modules:

- logging: Activity logging service
- pipedrive: Pipedrive CRM integration
- elevenlabs: ElevenLabs voice AI integration
- google_calendar: Google Calendar OAuth and sync
- scheduler: Call scheduling and pre-programming logic

All functions are re-exported here for backward compatibility.
"""

# ============================================================================
# Logging Service
# ============================================================================
from .logging import log_activity

# ============================================================================
# Pipedrive Integration
# ============================================================================
from .pipedrive import (
    extract_domain_from_email,
    extract_domains_from_meeting,
    get_pipedrive_api_client,
    get_pipedrive_deal_by_meeting,
    find_pipedrive_organization_by_domain,
    get_pipedrive_deals_for_organization,
    create_or_update_deal,
    sync_note_to_pipedrive,
)

# ============================================================================
# ElevenLabs Integration
# ============================================================================
from .elevenlabs import (
    fetch_call_status_from_elevenlabs,
    sync_call_status_from_api,
    get_elevenlabs_webhook_config,
    update_elevenlabs_webhook,
    format_prompt_with_context,
    format_first_message_with_context,
    trigger_agent_call,
)

# ============================================================================
# Google Calendar Integration
# ============================================================================
from .google_calendar import (
    SCOPES,
    get_google_credentials,
    refresh_google_credentials,
    get_google_calendar_service,
    create_meeting_from_event,
    update_meeting_from_event,
    sync_google_calendar,
    setup_google_calendar_watch,
    stop_google_calendar_watch,
    handle_google_calendar_notification,
)

# ============================================================================
# Scheduler Logic
# ============================================================================
from .scheduler import (
    pre_program_meeting_calls,
    cleanup_cancelled_meeting_calls,
    should_trigger_pre_call,
    should_trigger_post_call,
    check_pre_meeting_calls,
    check_post_meeting_calls,
)

# ============================================================================
# Public API - All exports
# ============================================================================
__all__ = [
    # Logging
    'log_activity',
    
    # Pipedrive
    'extract_domain_from_email',
    'extract_domains_from_meeting',
    'get_pipedrive_api_client',
    'get_pipedrive_deal_by_meeting',
    'find_pipedrive_organization_by_domain',
    'get_pipedrive_deals_for_organization',
    'create_or_update_deal',
    'sync_note_to_pipedrive',
    
    # ElevenLabs
    'fetch_call_status_from_elevenlabs',
    'sync_call_status_from_api',
    'get_elevenlabs_webhook_config',
    'update_elevenlabs_webhook',
    'format_prompt_with_context',
    'format_first_message_with_context',
    'trigger_agent_call',
    
    # Google Calendar
    'SCOPES',
    'get_google_credentials',
    'refresh_google_credentials',
    'get_google_calendar_service',
    'create_meeting_from_event',
    'update_meeting_from_event',
    'sync_google_calendar',
    'setup_google_calendar_watch',
    'stop_google_calendar_watch',
    'handle_google_calendar_notification',
    
    # Scheduler
    'pre_program_meeting_calls',
    'cleanup_cancelled_meeting_calls',
    'should_trigger_pre_call',
    'should_trigger_post_call',
    'check_pre_meeting_calls',
    'check_post_meeting_calls',
]
