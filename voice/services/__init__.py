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
# ============================================================================
# Calendar Abstraction Layer
# ============================================================================
from voice.calendar import get_calendar_provider

# ============================================================================
# CRM Abstraction Layer
# ============================================================================
from voice.crm import get_crm_provider

# ============================================================================
# Prompt Assembly (PRE_CALL / POST_CALL)
# ============================================================================
from .assembler import assemble_post_call, assemble_pre_call

# ============================================================================
# Client Sync
# ============================================================================
from .client_sync import enrich_client_from_crm, sync_all_clients, sync_single_client

# ============================================================================
# ElevenLabs Integration
# ============================================================================
from .elevenlabs import (
    fetch_call_status_from_elevenlabs,
    format_first_message_with_context,
    format_prompt_with_context,
    sync_call_status_from_api,
    trigger_agent_call,
)

# ============================================================================
# Google Calendar Integration
# ============================================================================
from .google_calendar import (
    SCOPES,
    get_google_calendar_service,
    get_google_credentials,
    handle_google_calendar_notification,
    refresh_google_credentials,
    setup_google_calendar_watch,
    stop_google_calendar_watch,
    sync_google_calendar,
)

# ============================================================================
# Lessons Distiller
# ============================================================================
from .lessons import distill_lessons

# ============================================================================
# LLM Service
# ============================================================================
from .llm import (
    extract_pdf_text,
    generate_client_summary,
    generate_voice_prompt,
    summarize_call_transcript,
    summarize_methodology_pdf,
)
from .logging import log_activity

# ============================================================================
# Pipedrive Integration
# ============================================================================
from .pipedrive import (
    create_or_update_deal,
    extract_domain_from_email,
    extract_domains_from_meeting,
    find_pipedrive_organization_by_domain,
    get_pipedrive_api_client,
    get_pipedrive_deal_by_meeting,
    get_pipedrive_deals_for_organization,
    sync_note_to_pipedrive,
)

# ============================================================================
# Scheduler Logic
# ============================================================================
from .scheduler import (
    check_post_meeting_calls,
    check_pre_meeting_calls,
    cleanup_cancelled_meeting_calls,
    pre_program_meeting_calls,
    should_trigger_post_call,
    should_trigger_pre_call,
)

# ============================================================================
# Visit Pipeline
# ============================================================================
from .visit_pipeline import (
    detect_visits_for_agent,
    detect_visits_for_all_agents,
    match_client_by_attendees,
)

# ============================================================================
# Public API - All exports
# ============================================================================
__all__ = [
    # Logging
    "log_activity",
    # Pipedrive
    "extract_domain_from_email",
    "extract_domains_from_meeting",
    "get_pipedrive_api_client",
    "get_pipedrive_deal_by_meeting",
    "find_pipedrive_organization_by_domain",
    "get_pipedrive_deals_for_organization",
    "create_or_update_deal",
    "sync_note_to_pipedrive",
    # ElevenLabs
    "fetch_call_status_from_elevenlabs",
    "sync_call_status_from_api",
    "format_prompt_with_context",
    "format_first_message_with_context",
    "trigger_agent_call",
    # Google Calendar
    "SCOPES",
    "get_google_credentials",
    "refresh_google_credentials",
    "get_google_calendar_service",
    "sync_google_calendar",
    "setup_google_calendar_watch",
    "stop_google_calendar_watch",
    "handle_google_calendar_notification",
    # CRM
    "get_crm_provider",
    # Calendar
    "get_calendar_provider",
    # Client Sync
    "sync_all_clients",
    "sync_single_client",
    "enrich_client_from_crm",
    # Visit Pipeline
    "detect_visits_for_agent",
    "detect_visits_for_all_agents",
    "match_client_by_attendees",
    # LLM
    "extract_pdf_text",
    "generate_client_summary",
    "generate_voice_prompt",
    "summarize_call_transcript",
    "summarize_methodology_pdf",
    # Prompt Builder
    "assemble_pre_call",
    "assemble_post_call",
    "distill_lessons",
    # Scheduler
    "pre_program_meeting_calls",
    "cleanup_cancelled_meeting_calls",
    "should_trigger_pre_call",
    "should_trigger_post_call",
    "check_pre_meeting_calls",
    "check_post_meeting_calls",
]
