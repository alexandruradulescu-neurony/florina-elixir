"""
Context-bundle assembly for the Auto Prompt Assembler.

Builds a dict of placeholders → values from a Visit (or Client, for LESSONS_DISTILL).
Used by voice/services/assembler.py and voice/services/lessons.py.

Security note (PR #5 review):
- `render_placeholders` uses regex substitution, NOT `str.format()` / `%`-formatting.
  Untrusted text inside placeholder VALUES (e.g. a meeting transcript or manager
  note) MUST NOT be evaluated as format-string syntax. `re.sub` with a callable
  cannot reach object attributes via `{0.__class__...}` tricks.
- The bundle wraps each untrusted text field with explicit fence delimiters
  (`<MANAGER_NOTES>...</MANAGER_NOTES>`) before substitution. The mega-prompt
  itself can then instruct Claude to treat fenced content as data, not
  instructions — soft mitigation against LLM prompt-injection in transcripts.
"""

from __future__ import annotations

import logging
import re
from typing import Any

from django.utils import timezone

from voice.models import Client, Visit


def _fmt_local_date(dt) -> str:
    """Format a datetime in the project's local timezone, YYYY-MM-DD."""
    if not dt:
        return "?"
    return timezone.localtime(dt).strftime("%Y-%m-%d")


def _fmt_local_datetime(dt) -> str:
    """Format a datetime in the project's local timezone, ``DD Month YYYY, HH:MM``.

    PR 6: was bare `dt.strftime(...)` which uses the datetime's INTERNAL tz
    (UTC for tz-aware DB rows) — Florina was reading visit times in UTC
    instead of Bucharest. `timezone.localtime` honors `settings.TIME_ZONE`.
    """
    if not dt:
        return ""
    return timezone.localtime(dt).strftime("%d %B %Y, %H:%M")


logger = logging.getLogger(__name__)


# Fields whose values may contain attacker-controlled text (manager input,
# meeting transcript, CRM-imported client summary). Wrapped with sentinel fences
# in the rendered context so the mega-prompt can tell Claude these blocks are
# DATA, never instructions.
_FENCED_KEYS = frozenset(
    {
        "manager_notes",
        "visit_transcript",
        "client_summary",
        "client_lessons_learned",
        "interaction_history",
        "client_past_visits",
        "agent_recent_visits",
        "pre_call_brief",
        "new_post_call_summary",
        "current_lessons_learned",
    }
)


# Per-fenced-field hard cap on character count. The mega-prompt budget is
# already constrained by Claude's context window; an attacker (or just an
# accidentally-huge transcript) could otherwise drive token cost arbitrarily.
# Generous enough to fit a long meeting transcript but bounded.
_MAX_FENCED_FIELD_CHARS = 20_000


def _neutralize_close_tags(value: str) -> str:
    """Defang sequences that could close a sentinel fence prematurely.

    PR #6 security finding #1: a transcript / manager note containing literal
    `</VISIT_TRANSCRIPT>` (or any `</TAG>`) could escape the data block and
    inject text outside the fenced region. We replace every `</` with `< /` —
    visually similar, semantically inert to a fence-pattern parser, but still
    readable to Claude. Operates on the value BEFORE the wrapping fence is
    added, so the OUTER tags are untouched.
    """
    return value.replace("</", "< /")


def _fence(key: str, value: str) -> str:
    """Wrap `value` with sentinel fences keyed by `key`.

    - Returns empty string if value is empty (so downstream rendering doesn't
      leave bare fence blocks in the meta-prompt).
    - Truncates value to `_MAX_FENCED_FIELD_CHARS` to bound LLM input cost.
    - Defangs any `</...>` close-tag patterns in the value so the fence
      cannot be escaped from the inside.
    """
    if not value:
        return ""
    if len(value) > _MAX_FENCED_FIELD_CHARS:
        value = value[:_MAX_FENCED_FIELD_CHARS] + "…[truncated]"
    safe = _neutralize_close_tags(value)
    tag = key.upper()
    return f"<{tag}>\n{safe}\n</{tag}>"


def _format_interaction_history(interactions: list[dict] | None) -> str:
    if not interactions:
        return ""
    lines = []
    for it in interactions[:5]:
        kind = it.get("type", "note")
        date = it.get("date", "")
        content = (it.get("content") or "")[:200]
        lines.append(f"- [{kind}] {date}: {content}")
    return "\n".join(lines)


def _format_deal_history(deals: list[dict] | None) -> str:
    if not deals:
        return ""
    lines = []
    for d in deals[:3]:
        title = d.get("title", "Untitled")
        status = d.get("status", "unknown")
        lines.append(f"- {title} (status: {status})")
    return "\n".join(lines)


def _format_past_visits(visits) -> str:
    """visits is an iterable of Visit instances."""
    if not visits:
        return ""
    lines = []
    for v in visits:
        date = _fmt_local_date(v.start_time)
        summary = (v.post_call_summary or "").strip()
        if summary:
            lines.append(f"- {date} · {v.title}\n  {summary[:400]}")
        else:
            lines.append(f"- {date} · {v.title} (no debrief)")
    return "\n".join(lines)


def build_pre_call_context(visit: Visit) -> dict[str, Any]:
    """Return placeholder→value dict for a PRE_CALL assembly."""
    client = visit.client
    methodology = visit.get_effective_methodology()
    past_client_visits = (
        Visit.objects.filter(client=client).exclude(pk=visit.pk).order_by("-start_time")[:3]
    )
    past_agent_visits = (
        Visit.objects.filter(agent=visit.agent).exclude(pk=visit.pk).order_by("-start_time")[:5]
    )

    raw_values = {
        "agent_first_name": visit.agent.first_name or visit.agent.username,
        "client_name": client.name,
        "client_industry": client.industry or "",
        "client_summary": client.ai_summary or "",
        "client_lessons_learned": client.lessons_learned or "",
        "visit_time": _fmt_local_datetime(visit.start_time),
        "scenario": visit.scenario.name if visit.scenario_id else "",
        "manager_notes": visit.manager_notes or "",
        "methodology_summary": (methodology.ai_summary if methodology else "") or "",
        "interaction_history": _format_interaction_history(client.interaction_history),
        "deal_history": _format_deal_history(client.deal_history),
        "client_past_visits": _format_past_visits(past_client_visits),
        "agent_recent_visits": _format_past_visits(past_agent_visits),
    }
    return _apply_fences(raw_values)


def build_post_call_context(visit: Visit, transcript: str = "") -> dict[str, Any]:
    """Return placeholder→value dict for a POST_CALL assembly.

    `transcript` is the meeting transcript (if available — may be empty).
    """
    pre = build_pre_call_context(visit)
    # Re-extend with post-only keys; rebuild fences for the additions only.
    post_only = {
        "pre_call_brief": visit.pre_call_prompt or "",
        "visit_transcript": transcript or "",
    }
    pre.update(_apply_fences(post_only))
    return pre


def build_lessons_context(
    client: Client,
    new_post_call_summary: str,
    evaluation_outcome: str,
) -> dict[str, Any]:
    """Return placeholder→value dict for a LESSONS_DISTILL run."""
    raw = {
        "current_lessons_learned": client.lessons_learned or "",
        "new_post_call_summary": new_post_call_summary or "",
        "evaluation_outcome": evaluation_outcome or "",
    }
    return _apply_fences(raw)


def _apply_fences(values: dict[str, Any]) -> dict[str, Any]:
    """Return a copy of `values` with untrusted fields wrapped in sentinel fences.

    Fields in `_FENCED_KEYS` get `<KEY>\\n…\\n</KEY>` wrapping so the mega-prompt
    can instruct Claude to treat them as inert data. Non-fenced keys pass
    through unchanged.
    """
    out: dict[str, Any] = {}
    for k, v in values.items():
        if k in _FENCED_KEYS and isinstance(v, str):
            out[k] = _fence(k, v)
        else:
            out[k] = v
    return out


# Strict placeholder pattern: `{NAME}` where NAME starts with a letter or underscore
# and contains only letters, digits, and underscores. We deliberately do NOT match
# anything with dots, brackets, or other punctuation — closes the door on the
# `{0.__class__.__base__.__subclasses__}` family of format-string exploits.
_PLACEHOLDER_RE = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}")


def render_placeholders(template: str, values: dict[str, Any]) -> str:
    """Substitute `{placeholder}` tokens in `template` with values from `values`.

    Implementation uses `re.sub` with a callable — never `str.format()` or `%`.
    Values are NEVER evaluated as templates themselves, so a value containing
    `{another_placeholder}` will appear literally in the output (not recursed).
    Unknown placeholders are left in place and logged at WARNING.
    """
    seen_unknown: set[str] = set()

    def repl(match: re.Match) -> str:
        key = match.group(1)
        if key in values:
            v = values[key]
            return str(v) if v is not None else ""
        if key not in seen_unknown:
            seen_unknown.add(key)
            logger.warning(
                "render_placeholders: unknown placeholder {%s} left untouched",
                key,
            )
        return match.group(0)

    return _PLACEHOLDER_RE.sub(repl, template)
