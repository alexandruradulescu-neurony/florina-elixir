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


def analyze_post_call(transcript: str, post_call_prompt: str = '', visit_context: str = '') -> Optional[dict]:
    """
    Analyze a post-call transcript and return structured fields for CRM/Visit Detail.

    Args:
        transcript: Full call transcript text (Agent/User turns).
        post_call_prompt: The prompt the AI used during the debrief — gives Claude
                          context on what the agent was probing for.
        visit_context: Free-form context about the visit (client, agent, methodology).

    Returns:
        dict matching the agreed schema, or None on failure.
    """
    import json

    schema = '''
{
  "summary": "<3-5 sentence CRM-ready paragraph in neutral business tone>",
  "objective_attained": "attained" | "partial" | "missed",
  "objective_assessment": "<one paragraph explaining whether the meeting objective was hit and why>",
  "actionables": [
    {"owner": "agent" | "client" | "other", "action": "<verb-led action>", "due": "<YYYY-MM-DD or null>"}
  ],
  "recommendations": ["<short string, what the agent should do differently or better next time>"],
  "next_best_actions": [
    {"action": "<concrete next step to drive the deal>", "rationale": "<why>", "timing": "today" | "within 7 days" | "within 30 days" | "<custom>"}
  ],
  "no_go": {
    "is_no_go": true | false,
    "reason": "<why the deal is dead, or null>",
    "salvage_path": "<what could revive it, or null, or 'abandoned'>"
  },
  "sentiment": "positive" | "neutral" | "negative" | "mixed",
  "sentiment_score": <integer 0-100>,
  "talk_ratio": {"agent": <integer 0-100>, "client": <integer 0-100>},
  "objections_raised": ["<short string>"],
  "objections_handled": ["<short string with how it was addressed>"],
  "champion_strength": "weak" | "moderate" | "strong" | "champion",
  "risks": ["<short string>"]
}
'''.strip()

    system = (
        "You are an expert sales operations analyst. You will read a post-meeting "
        "debrief transcript between an AI coach and a sales agent. The agent was "
        "asked specific questions about a recent client meeting. Your job is to "
        "extract structured analysis suitable for a CRM and a sales manager "
        "dashboard.\n\n"
        "Return ONLY a single JSON object matching this schema, with no prose, "
        "no markdown fences, no commentary:\n\n"
        f"{schema}\n\n"
        "Rules:\n"
        "- talk_ratio.agent + talk_ratio.client must sum to 100.\n"
        "- sentiment_score must be an integer 0-100.\n"
        "- objective_attained must be exactly one of: 'attained', 'partial', 'missed'.\n"
        "- If is_no_go is false, reason and salvage_path may be null.\n"
        "- Use empty arrays for missing list fields, not null.\n"
        "- Be specific and concrete in actionables and next_best_actions — avoid vague verbs.\n"
        "- If the transcript is too short or empty to analyze, return all-empty defaults but valid JSON."
    )

    parts = []
    if visit_context:
        parts.append(f"## Visit context\n{visit_context}")
    if post_call_prompt:
        parts.append(f"## Original debrief prompt (what the AI was probing for)\n{post_call_prompt}")
    parts.append(f"## Transcript\n{transcript}")
    user_msg = "\n\n".join(parts)

    raw = _call_claude(system, user_msg, max_tokens=4096)
    if not raw:
        return None

    # Strip optional markdown fences if Claude added them anyway
    text = raw.strip()
    if text.startswith("```"):
        # Remove leading ```json or ``` and trailing ```
        text = text.split("```", 2)
        if len(text) >= 3:
            text = text[1]
            if text.startswith("json"):
                text = text[4:]
            text = text.strip()
        else:
            text = raw.strip()

    try:
        data = json.loads(text)
        if not isinstance(data, dict):
            raise ValueError("Expected JSON object")
        return data
    except (json.JSONDecodeError, ValueError) as e:
        logger.error(f"Claude returned invalid JSON for post-call analysis: {e}\nRaw: {raw[:500]}")
        return None


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
