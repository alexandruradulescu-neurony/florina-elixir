"""
LLM Service — Claude API integration.

Handles all LLM calls for:
- PDF methodology summarization
- Pre/post call voice prompt generation
- Post-call transcript summarization
- Client profile AI summary generation
"""

import logging

from decouple import config

logger = logging.getLogger(__name__)

_client = None


def _resolve_anthropic_key() -> str:
    """Resolve ANTHROPIC_API_KEY robustly.

    decouple.config picks up the value from os.environ first. If a parent shell
    exported the variable as an empty string (e.g. another tool stub), decouple
    returns that empty string and ignores the real value in .env. This breaks
    the webhook silently in production-like setups. As a fallback, when
    decouple yields an empty value, we read .env directly.
    """
    key = config("ANTHROPIC_API_KEY", default="") or ""
    if key.strip():
        return key.strip()
    try:
        import os

        from decouple import RepositoryEnv

        env_path = os.path.join(os.getcwd(), ".env")
        if os.path.exists(env_path):
            data = RepositoryEnv(env_path).data
            fallback = (data.get("ANTHROPIC_API_KEY") or "").strip()
            if fallback:
                return fallback
    except Exception as e:
        logger.warning(f"Could not read ANTHROPIC_API_KEY from .env file: {e}")
    return ""


def _get_client():
    """Lazy-init the Anthropic client."""
    global _client
    if _client is None:
        import anthropic

        api_key = _resolve_anthropic_key()
        if not api_key:
            raise ValueError("ANTHROPIC_API_KEY not configured in .env")
        _client = anthropic.Anthropic(api_key=api_key)
    return _client


def is_configured() -> bool:
    """Check if the LLM service has a valid API key."""
    return bool(_resolve_anthropic_key())


def _call_claude(system_prompt: str, user_message: str, max_tokens: int = 4096) -> str | None:
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
            model=config("LLM_MODEL", default="claude-sonnet-4-20250514"),
            max_tokens=max_tokens,
            system=system_prompt,
            messages=[{"role": "user", "content": user_message}],
        )
        return response.content[0].text
    except Exception as e:
        logger.error(f"Claude API call failed: {e}", exc_info=True)
        return None


def _call_claude_with_usage(
    system_prompt: str,
    user_message: str,
    max_tokens: int = 4096,
) -> tuple[str | None, int, int]:
    """Like _call_claude, but also returns (input_tokens, output_tokens).

    Returns (text_or_none, input_tokens, output_tokens). On failure, returns
    (None, 0, 0).
    """
    try:
        client = _get_client()
        response = client.messages.create(
            model=config("LLM_MODEL", default="claude-sonnet-4-20250514"),
            max_tokens=max_tokens,
            system=system_prompt,
            messages=[{"role": "user", "content": user_message}],
        )
        text = response.content[0].text
        in_tok = getattr(response.usage, "input_tokens", 0) or 0
        out_tok = getattr(response.usage, "output_tokens", 0) or 0
        return text, in_tok, out_tok
    except Exception as e:
        logger.error(f"Claude API call failed: {e}", exc_info=True)
        return None, 0, 0


def summarize_methodology_pdf(pdf_text: str) -> str | None:
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


def generate_voice_prompt(meta_prompt: str, context: str) -> str | None:
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


def summarize_call_transcript(transcript: str, visit_context: str = "") -> str | None:
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


def summarize_call_transcript_ro(
    transcript: str,
    phase: str = "pre",
    visit_context: str = "",
    original_prompt: str = "",
) -> str | None:
    """
    Summarize a call transcript in Romanian, suitable for the Visit Detail panel.

    Used for BOTH pre-call (preparation) and post-call (debrief) transcripts. The
    result overwrites the English summary that ElevenLabs returns in its analysis
    block, so the UI shows Romanian everywhere.

    Args:
        transcript: Full call transcript text.
        phase: 'pre' for pre-call (preparation), 'post' for post-call (debrief).
        visit_context: Optional context about the visit (client, agent, methodology).
        original_prompt: The prompt the AI used during the call (for context).

    Returns:
        2-4 sentence Romanian summary string, or None on failure.
    """
    if phase == "post":
        phase_word = "apelului de debrief (după întâlnire)"
        guidance = (
            "Cum a decurs întâlnirea, ce intel nou avem despre client, dacă obiectivul a fost "
            "atins sau ratat, ce s-a promis și care sunt pașii imediat următori."
        )
    else:
        phase_word = "apelului de pregătire (înainte de întâlnire)"
        guidance = (
            "Ce am verificat împreună cu agentul, ce a confirmat că are pregătit, ce gap-uri "
            "am identificat și ce-i trimite Florina pe email înainte de întâlnire."
        )
    system = (
        f"Ești un asistent senior de vânzări B2B în România. Vei rezuma transcriptul {phase_word} "
        "într-un paragraf clar, în română, de 2-4 fraze. Acest sumar se afișează direct în "
        "interfața de vizită — așa că trebuie să fie concret, util și ușor de citit la o "
        "scanare rapidă de către un manager de vânzări care nu a participat la apel.\n\n"
        f"Focus: {guidance}\n\n"
        "Reguli stricte:\n"
        "- Întoarce DOAR textul sumarului. Fără titluri, fără markdown, fără bulleturi.\n"
        "- Maxim 4 fraze.\n"
        "- Folosește limba română pe tot textul.\n"
        "- Nu inventa detalii care nu apar în transcript. Dacă transcriptul e foarte scurt sau "
        "neclar, spune scurt asta în loc să fabrici."
    )
    parts = []
    if visit_context:
        parts.append(f"## Context vizită\n{visit_context}")
    if original_prompt:
        parts.append(f"## Promptul folosit de Florina în apel (referință)\n{original_prompt}")
    parts.append(f"## Transcript apel\n{transcript}")
    user_msg = "\n\n".join(parts)
    return _call_claude(system, user_msg, max_tokens=512)


def generate_client_summary(client_data: dict) -> str | None:
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
    return "\n\n".join(text_parts)


def analyze_post_call(
    transcript: str,
    post_call_prompt: str = "",
    visit_context: str = "",
    pre_call_summary: str = "",
) -> dict | None:
    """
    Analyze a post-call transcript and return structured fields for CRM/Visit Detail.

    Args:
        transcript: Full call transcript text (Agent/User turns).
        post_call_prompt: The prompt the AI used during the debrief — gives Claude
                          context on what the agent was probing for.
        visit_context: Free-form context about the visit (client, agent, methodology).
        pre_call_summary: Romanian summary of the pre-call. If present, Claude
                          actively compares pre-call claims vs post-call reality
                          and flags discrepancies in `consistency_check`.

    Returns:
        dict matching the agreed schema, or None on failure.
    """
    import json

    schema = """
{
  "summary": "<3-5 fraze în română, ton de notă CRM curată: ce s-a întâmplat, ce s-a aflat, ce urmează. Fără jargon corporate.>",
  "objective_attained": "attained" | "partial" | "missed",
  "objective_assessment": "<un paragraf în română care explică dacă obiectivul vizitei a fost atins și de ce>",
  "actionables": [
    {"owner": "agent" | "client" | "other", "action": "<acțiune concretă în română, începe cu un verb la imperativ>", "due": "<YYYY-MM-DD sau null>"}
  ],
  "recommendations": ["<recomandare în română — ce ar trebui agentul să facă diferit sau mai bine data viitoare>"],
  "next_best_actions": [
    {"action": "<următorul pas concret în relația cu clientul, în română>", "rationale": "<de ce, în română>", "timing": "today" | "within 7 days" | "within 30 days" | "<custom>"}
  ],
  "no_go": {
    "is_no_go": true | false,
    "reason": "<de ce nu mergem mai departe, în română, sau null>",
    "salvage_path": "<cum ar putea totuși fi salvată relația, în română, sau null, sau 'abandoned'>"
  },
  "sentiment": "positive" | "neutral" | "negative" | "mixed",
  "sentiment_score": <integer 0-100>,
  "talk_ratio": {"agent": <integer 0-100>, "client": <integer 0-100>},
  "objections_raised": ["<obiecție ridicată de client, formulare scurtă în română>"],
  "objections_handled": ["<cum a fost gestionată obiecția, în română>"],
  "champion_strength": "weak" | "moderate" | "strong" | "champion",
  "risks": ["<risc concret pentru deal, în română>"],
  "consistency_check": {
    "has_pre_call_summary": true | false,
    "consistent": true | false,
    "discrepancies": [
      {
        "pre_call_claim": "<ce a spus / ce a confirmat agentul la pre-call, în română>",
        "post_call_reality": "<ce reiese din debrief că s-a întâmplat de fapt, în română>",
        "implication": "<ce înseamnă pentru deal sau pentru relația cu agentul, în română>"
      }
    ]
  }
}
""".strip()

    system = (
        "Ești un analist senior de vânzări B2B în România. Vei citi transcriptul unui apel "
        "de debrief între un asistent AI (Florina) și un agent de vânzări care tocmai s-a "
        "întors de la o întâlnire cu un client. Promptul folosit în apelul de debrief îți "
        "este oferit ca ghid contextual — îți spune ce voia agentul să afle.\n\n"
        "Sarcina ta: extragi din transcript o analiză structurată, gata de pus în CRM și "
        "într-un dashboard de sales manager. Câmpul `summary` se va folosi DIRECT ca notă CRM "
        "— scrie-l clar, concret, util pentru un manager care nu a fost la întâlnire.\n\n"
        "Important: TOATE CÂMPURILE DE TEXT TREBUIE SĂ FIE ÎN ROMÂNĂ. Doar enumerările "
        "(values precum 'attained', 'positive', 'within 7 days', 'agent', 'client') rămân "
        "în engleză așa cum sunt în schemă.\n\n"
        "Întoarci EXCLUSIV un singur obiect JSON valid care respectă schema de mai jos, "
        "fără proză, fără markdown fences, fără comentarii:\n\n"
        f"{schema}\n\n"
        "Reguli:\n"
        "- talk_ratio.agent + talk_ratio.client trebuie să dea exact 100.\n"
        "- sentiment_score este un întreg între 0 și 100.\n"
        "- objective_attained este exact una din: 'attained', 'partial', 'missed'.\n"
        "- Dacă is_no_go e false, reason și salvage_path pot fi null.\n"
        "- Pentru câmpurile lista, folosește array gol [] dacă nu există date, nu null.\n"
        "- În actionables și next_best_actions fii specific și concret — evită verbe vagi "
        "('a urmări', 'a verifica') fără context. Formulări ca 'trimite oferta pentru ciment "
        "BCA până vineri' sau 'programează vizită la fabrică săptămâna viitoare' sunt bune.\n"
        "- Detectează semnale de NO-GO real (refuz categoric, probleme financiare grave la "
        "client, schimbare de strategie) și marchează corect.\n"
        "- Nu inventa detalii care nu apar în transcript. Dacă agentul nu a confirmat un "
        "lucru, nu pune în CRM ca și cum ar fi confirmat.\n"
        "- Dacă transcriptul e prea scurt sau gol ca să tragi concluzii, întoarce valori "
        "default goale dar JSON valid.\n"
        "\n"
        "VERIFICAREA CONSISTENȚEI PRE↔POST (consistency_check):\n"
        "- Dacă există un sumar al pre-call-ului în context, compară activ ce a CONFIRMAT "
        "agentul că știe/are pregătit la pre-call versus ce reiese din debrief.\n"
        "- Exemple de discrepanțe relevante: agentul a zis la pre-call că a verificat "
        "solvabilitatea pe listafirme, dar la post-call recunoaște că nu a apucat. Sau "
        "a confirmat că are fișa de produs gata, dar la întâlnire nu a prezentat-o.\n"
        "- has_pre_call_summary = true doar dacă efectiv ai primit un sumar de pre-call în "
        "context. Dacă nu, has_pre_call_summary = false, consistent = true, discrepancies = [].\n"
        "- Dacă nu există discrepanțe relevante, consistent = true și discrepancies = [].\n"
        "- Nu raporta discrepanțe minore de formulare. Doar lucruri care chiar contează "
        "pentru deal sau pentru calitatea pregătirii agentului."
    )

    parts = []
    if visit_context:
        parts.append(f"## Context vizită\n{visit_context}")
    if pre_call_summary and pre_call_summary.strip():
        parts.append(
            f"## Sumar pre-call (folosește pentru consistency_check)\n{pre_call_summary.strip()}"
        )
    if post_call_prompt:
        parts.append(
            f"## Promptul folosit de Florina în debrief (ce voia agentul să afle)\n{post_call_prompt}"
        )
    parts.append(f"## Transcript apel\n{transcript}")
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


def chat_with_data(messages: list, data_context: str) -> str | None:
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
            model=config("LLM_MODEL", default="claude-sonnet-4-20250514"),
            max_tokens=2048,
            system=system_prompt,
            messages=messages,
        )
        return response.content[0].text
    except Exception as e:
        logger.error(f"Live agent chat failed: {e}", exc_info=True)
        return None
