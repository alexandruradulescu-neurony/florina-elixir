"""
Prompt Builder Service.

Assembles context from multiple sources and calls the LLM to generate
voice call prompts for ElevenLabs.

Two-step architecture:
  1. Assemble context (client + methodology + CRM + manager notes)
  2. Send meta-prompt + context to Claude → get voice prompt
  3. Voice prompt is injected into ElevenLabs call
"""
import logging
from typing import Optional

from voice.models import Visit, GlobalSettings
from .llm import generate_voice_prompt, is_configured as llm_configured
from .logging import log_activity
from voice.constants import LogLevel

logger = logging.getLogger(__name__)

# Default meta-prompts used when GlobalSettings fields are empty
DEFAULT_PRE_CALL_META_PROMPT = """\
You are a prompt engineer for a voice AI sales coach. \
Generate a conversational voice prompt that an AI phone agent will use \
to call a sales representative BEFORE their upcoming meeting.

The voice agent should:
- Greet the agent by name
- Brief them on the client and relevant history
- Guide them through the preparation methodology
- Ask if they have specific questions or concerns about the meeting
- Keep the tone professional but encouraging

Generate ONLY the voice prompt text — no explanations or metadata.\
"""

DEFAULT_POST_CALL_META_PROMPT = """\
You are a prompt engineer for a voice AI sales coach. \
Generate a conversational voice prompt that an AI phone agent will use \
to call a sales representative AFTER their meeting.

The voice agent should:
- Ask how the meeting went
- Probe for key outcomes: what was discussed, decisions made, next steps
- Ask about the client's sentiment and engagement level
- Capture any commitments or follow-up actions
- Keep the tone conversational and supportive

Generate ONLY the voice prompt text — no explanations or metadata.\
"""


def _assemble_pre_call_context(visit: Visit) -> str:
    """Build the context block for a pre-call prompt generation."""
    parts = []

    # Client context
    client = visit.client
    parts.append("## Client")
    parts.append(f"Name: {client.name}")
    if client.industry:
        parts.append(f"Industry: {client.industry}")
    if client.ai_summary:
        parts.append(f"\n### Client Summary\n{client.ai_summary}")
    if client.interaction_history:
        recent = client.interaction_history[:5]  # Last 5 interactions
        parts.append("\n### Recent Interactions")
        for interaction in recent:
            parts.append(f"- [{interaction.get('type', 'note')}] {interaction.get('date', '')}: {interaction.get('content', '')[:200]}")
    if client.deal_history:
        parts.append("\n### Active Deals")
        for deal in client.deal_history[:3]:
            parts.append(f"- {deal.get('title', 'Untitled')} (status: {deal.get('status', 'unknown')})")

    # Methodology
    methodology = visit.get_effective_methodology()
    if methodology and methodology.ai_summary:
        parts.append(f"\n## Methodology: {methodology.name}")
        parts.append(methodology.ai_summary)

    # Visit details
    parts.append("\n## Visit Details")
    parts.append(f"Title: {visit.title}")
    parts.append(f"Date/Time: {visit.start_time.strftime('%B %d, %Y at %I:%M %p')}")
    parts.append(f"Agent: {visit.agent.get_full_name() or visit.agent.username}")
    if visit.attendees:
        parts.append(f"Attendees: {', '.join(visit.attendees)}")
    if visit.crm_deal_id:
        parts.append(f"CRM Deal ID: {visit.crm_deal_id}")

    # Manager notes
    if visit.manager_notes:
        parts.append(f"\n## Manager Notes\n{visit.manager_notes}")

    return '\n'.join(parts)


def _assemble_post_call_context(visit: Visit) -> str:
    """Build the context block for a post-call prompt generation."""
    parts = []

    # Client basics
    parts.append(f"## Client: {visit.client.name}")

    # Visit details
    parts.append(f"\n## Visit: {visit.title}")
    parts.append(f"Agent: {visit.agent.get_full_name() or visit.agent.username}")
    parts.append(f"Date: {visit.start_time.strftime('%B %d, %Y at %I:%M %p')}")

    # Pre-call context (what was discussed before the meeting)
    if visit.pre_call_prompt:
        parts.append("\n## Pre-Call Brief (what the agent was coached on)")
        parts.append(visit.pre_call_prompt[:500])  # Truncate if very long

    # Manager notes
    if visit.manager_notes:
        parts.append(f"\n## Manager Notes\n{visit.manager_notes}")

    return '\n'.join(parts)


def generate_pre_call_prompt(visit: Visit) -> Optional[str]:
    """
    Generate the voice prompt for a pre-meeting call.

    Steps:
      1. Get meta-prompt from GlobalSettings (or default)
      2. Assemble context from client, methodology, CRM, manager notes
      3. Call Claude to generate the voice prompt
      4. Save to visit.pre_call_prompt

    Returns:
        Generated prompt string, or None on failure.
    """
    if not llm_configured():
        logger.warning("LLM not configured, cannot generate pre-call prompt")
        return None

    settings = GlobalSettings.load()
    meta_prompt = settings.pre_call_meta_prompt or DEFAULT_PRE_CALL_META_PROMPT
    context = _assemble_pre_call_context(visit)

    prompt = generate_voice_prompt(meta_prompt, context)
    if prompt:
        visit.pre_call_prompt = prompt
        visit.save(update_fields=['pre_call_prompt', 'updated_at'])
        log_activity(
            user=visit.agent,
            action=f"Pre-call prompt generated for visit: {visit.title}",
            details={'visit_id': visit.id, 'prompt_length': len(prompt)},
        )
    else:
        log_activity(
            user=visit.agent,
            action=f"Pre-call prompt generation failed for visit: {visit.title}",
            details={'visit_id': visit.id},
            level=LogLevel.ERROR,
        )

    return prompt


def generate_post_call_prompt(visit: Visit) -> Optional[str]:
    """
    Generate the voice prompt for a post-meeting call.

    Returns:
        Generated prompt string, or None on failure.
    """
    if not llm_configured():
        logger.warning("LLM not configured, cannot generate post-call prompt")
        return None

    settings = GlobalSettings.load()
    meta_prompt = settings.post_call_meta_prompt or DEFAULT_POST_CALL_META_PROMPT
    context = _assemble_post_call_context(visit)

    prompt = generate_voice_prompt(meta_prompt, context)
    if prompt:
        visit.post_call_prompt = prompt
        visit.save(update_fields=['post_call_prompt', 'updated_at'])
        log_activity(
            user=visit.agent,
            action=f"Post-call prompt generated for visit: {visit.title}",
            details={'visit_id': visit.id, 'prompt_length': len(prompt)},
        )
    else:
        log_activity(
            user=visit.agent,
            action=f"Post-call prompt generation failed for visit: {visit.title}",
            details={'visit_id': visit.id},
            level=LogLevel.ERROR,
        )

    return prompt
