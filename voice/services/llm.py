"""
LLM Service — Claude API integration.

Handles all LLM calls for:
- PDF methodology summarization
- Pre/post call voice prompt generation
- Post-call transcript summarization
- Client profile AI summary generation
"""
import logging
from typing import Optional

from decouple import config

logger = logging.getLogger(__name__)

_client = None


def _get_client():
    """Lazy-init the Anthropic client."""
    global _client
    if _client is None:
        import anthropic
        api_key = config('ANTHROPIC_API_KEY', default='')
        if not api_key:
            raise ValueError("ANTHROPIC_API_KEY not configured in .env")
        _client = anthropic.Anthropic(api_key=api_key)
    return _client


def is_configured() -> bool:
    """Check if the LLM service has a valid API key."""
    return bool(config('ANTHROPIC_API_KEY', default=''))


def _call_claude(system_prompt: str, user_message: str, max_tokens: int = 4096) -> Optional[str]:
    """
    Make a single Claude API call.

    Args:
        system_prompt: System instructions.
        user_message: User content.
        max_tokens: Max response tokens.

    Returns:
        Response text or None on failure.
    """
    try:
        client = _get_client()
        response = client.messages.create(
            model=config('LLM_MODEL', default='claude-sonnet-4-20250514'),
            max_tokens=max_tokens,
            system=system_prompt,
            messages=[{"role": "user", "content": user_message}],
        )
        return response.content[0].text
    except Exception as e:
        logger.error(f"Claude API call failed: {e}", exc_info=True)
        return None


def summarize_methodology_pdf(pdf_text: str) -> Optional[str]:
    """
    Summarize a methodology PDF into a structured reference for voice prompts.

    Args:
        pdf_text: Extracted text content from the PDF.

    Returns:
        Structured summary string, or None on failure.
    """
    system = (
        "You are an expert in sales methodologies. "
        "Summarize the following sales methodology document into a structured reference "
        "that can be used to guide a voice AI coaching call with a sales agent. "
        "Focus on: key principles, conversation framework/steps, "
        "recommended questions to ask, and common pitfalls to avoid. "
        "Keep it concise but actionable — this will be injected into a voice prompt."
    )
    return _call_claude(system, pdf_text, max_tokens=2048)


def generate_voice_prompt(meta_prompt: str, context: str) -> Optional[str]:
    """
    Generate a voice call prompt using a meta-prompt and assembled context.

    This is the core of the two-step prompt architecture:
    1. meta_prompt tells Claude HOW to write the voice prompt
    2. context provides the data (client, methodology, deal, manager notes)
    3. Claude generates the actual conversational prompt for ElevenLabs

    Args:
        meta_prompt: Instructions for generating the voice prompt.
        context: Assembled context data (client info, methodology, etc.)

    Returns:
        Generated voice prompt string, or None on failure.
    """
    return _call_claude(meta_prompt, context, max_tokens=2048)


def summarize_call_transcript(transcript: str, visit_context: str = '') -> Optional[str]:
    """
    Summarize a post-call transcript into a structured note for CRM.

    Args:
        transcript: Full call transcript text.
        visit_context: Optional context about the visit (client, meeting title, etc.)

    Returns:
        Structured summary string, or None on failure.
    """
    system = (
        "You are a sales operations assistant. "
        "Summarize the following post-meeting debrief call transcript into a concise, "
        "structured note suitable for a CRM deal record. "
        "Include: key discussion points, outcomes, next steps, "
        "and any commitments made. Keep it professional and factual."
    )
    user_msg = transcript
    if visit_context:
        user_msg = f"## Visit Context\n{visit_context}\n\n## Transcript\n{transcript}"
    return _call_claude(system, user_msg, max_tokens=1024)


def generate_client_summary(client_data: dict) -> Optional[str]:
    """
    Generate an AI summary of a client from CRM data.

    Args:
        client_data: Dict with name, industry, contacts, deal_history, interaction_history.

    Returns:
        Client profile summary string, or None on failure.
    """
    system = (
        "You are a sales intelligence assistant. "
        "Create a brief client profile summary from the following CRM data. "
        "Highlight: company overview, key contacts and their roles, "
        "deal history and current status, recent interactions, "
        "and any patterns or insights that would help a sales agent prepare for a meeting. "
        "Be concise — this will be used as context in a voice coaching call."
    )
    import json
    user_msg = json.dumps(client_data, indent=2, default=str)
    return _call_claude(system, user_msg, max_tokens=1024)


def extract_pdf_text(file_path: str) -> str:
    """
    Extract text content from a PDF file.

    Args:
        file_path: Path to the PDF file.

    Returns:
        Extracted text string.
    """
    import pdfplumber

    text_parts = []
    with pdfplumber.open(file_path) as pdf:
        for page in pdf.pages:
            page_text = page.extract_text()
            if page_text:
                text_parts.append(page_text)
    return '\n\n'.join(text_parts)


def chat_with_data(messages: list, data_context: str) -> Optional[str]:
    """
    Multi-turn chat with database context for the Live Agent feature.

    Args:
        messages: List of {"role": "user"|"assistant", "content": "..."} dicts.
        data_context: Assembled database snapshot text.

    Returns:
        Assistant response text, or None on failure.
    """
    system_prompt = (
        "You are a Sales Assistant AI — a helpful data analyst for a sales manager. "
        "You have access to the current state of the sales database below. "
        "Answer questions accurately based on this data. "
        "Be concise and direct. Use numbers when available. "
        "If you don't have enough data to answer, say so honestly. "
        "Format responses with markdown when helpful (lists, bold, tables). "
        "Never make up data — only reference what's in the context below.\n\n"
        f"## DATABASE SNAPSHOT\n{data_context}"
    )
    try:
        client = _get_client()
        response = client.messages.create(
            model=config('LLM_MODEL', default='claude-sonnet-4-20250514'),
            max_tokens=2048,
            system=system_prompt,
            messages=messages,
        )
        return response.content[0].text
    except Exception as e:
        logger.error(f"Live agent chat failed: {e}", exc_info=True)
        return None
