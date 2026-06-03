"""
LESSONS_DISTILL — closed-loop update of `Client.lessons_learned` after every
post-call. Runs as a follow-up step from the end-of-meeting flow:

    1. assemble_post_call() finishes
    2. process_visit_post_call_completion() writes the post_call_summary
    3. distill_lessons() reads the new summary + current lessons_learned and
       produces an updated lessons_learned block (respecting manual edits)

Public entry point:

    distill_lessons(client, new_post_call_summary, evaluation_outcome,
                    triggered_by="END_OF_MEETING", user=None) -> GenerationRun

Like the assembler, distillation NEVER raises to the caller — every failure
mode is captured in a `GenerationRun` row with `success=False` and a
descriptive `error`, so the post-call success path can always proceed.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from voice.models import Client, GenerationRun, MegaPrompt
from voice.services.assembler import SYSTEM_PROMPT, _parse_response, _record_run
from voice.services.llm import _call_claude_with_usage, is_configured
from voice.services.prompt_context import build_lessons_context, render_placeholders

logger = logging.getLogger(__name__)

# Defense-in-depth cap. The distill prompt instructs Claude to produce <= 400
# words; pad for variance. A wildly oversized response indicates the call ran
# away and we should reject it rather than persist runaway content.
_MAX_LESSONS_CHARS = 20_000


def _validate_lessons(parsed: dict[str, Any]) -> str:
    """Validate the `{lessons_learned}` shape and return the string."""
    value = parsed.get("lessons_learned", "")
    if not isinstance(value, str):
        raise ValueError(f"`lessons_learned` must be a string, got {type(value).__name__}")
    if not value.strip():
        raise ValueError("`lessons_learned` is empty after stripping whitespace")
    if len(value) > _MAX_LESSONS_CHARS:
        raise ValueError(f"`lessons_learned` exceeds {_MAX_LESSONS_CHARS} chars ({len(value)})")
    return value


def distill_lessons(
    client: Client,
    new_post_call_summary: str,
    evaluation_outcome: str,
    triggered_by: str = GenerationRun.TriggeredBy.END_OF_MEETING,
    user=None,
) -> GenerationRun:
    """Run LESSONS_DISTILL for `client`, updating its `lessons_learned`.

    Always returns a `GenerationRun` (persisted via `_record_run`). On any
    failure the `Client.lessons_learned` field is left untouched — the next
    successful distill picks up where this one stopped.
    """
    domain = MegaPrompt.Domain.LESSONS_DISTILL
    mega = MegaPrompt.objects.filter(domain=domain, is_active=True).first()
    if mega is None:
        error = f"No active MegaPrompt for {domain}"
        logger.error("Lessons distiller aborted: %s (client=%s)", error, client.pk)
        return _record_run(
            visit=None,
            client=client,
            domain=domain,
            mega_prompt=None,
            triggered_by=triggered_by,
            user=user,
            context_bundle={},
            claude_request="",
            claude_response="",
            parsed_outputs={},
            input_tokens=0,
            output_tokens=0,
            success=False,
            error=error,
        )

    context = build_lessons_context(client, new_post_call_summary, evaluation_outcome)
    rendered = render_placeholders(mega.meta_prompt, context)

    if not is_configured():
        return _record_run(
            visit=None,
            client=client,
            domain=domain,
            mega_prompt=mega,
            triggered_by=triggered_by,
            user=user,
            context_bundle=context,
            claude_request=rendered,
            claude_response="",
            parsed_outputs={},
            input_tokens=0,
            output_tokens=0,
            success=False,
            error="LLM not configured",
        )

    raw, in_tok, out_tok = _call_claude_with_usage(
        system_prompt=SYSTEM_PROMPT,
        user_message=rendered,
        max_tokens=2048,
    )
    if raw is None:
        return _record_run(
            visit=None,
            client=client,
            domain=domain,
            mega_prompt=mega,
            triggered_by=triggered_by,
            user=user,
            context_bundle=context,
            claude_request=rendered,
            claude_response="",
            parsed_outputs={},
            input_tokens=in_tok,
            output_tokens=out_tok,
            success=False,
            error="Claude API call returned None",
        )

    parsed: dict[str, Any] = {}
    try:
        parsed = _parse_response(raw)
        new_lessons = _validate_lessons(parsed)
    except (ValueError, json.JSONDecodeError) as e:
        return _record_run(
            visit=None,
            client=client,
            domain=domain,
            mega_prompt=mega,
            triggered_by=triggered_by,
            user=user,
            context_bundle=context,
            claude_request=rendered,
            claude_response=raw,
            parsed_outputs=parsed,
            input_tokens=in_tok,
            output_tokens=out_tok,
            success=False,
            error=f"Validation error: {e}",
        )

    client.lessons_learned = new_lessons
    client.save(update_fields=["lessons_learned", "updated_at"])

    return _record_run(
        visit=None,
        client=client,
        domain=domain,
        mega_prompt=mega,
        triggered_by=triggered_by,
        user=user,
        context_bundle=context,
        claude_request=rendered,
        claude_response=raw,
        parsed_outputs=parsed,
        input_tokens=in_tok,
        output_tokens=out_tok,
        success=True,
        error="",
    )
