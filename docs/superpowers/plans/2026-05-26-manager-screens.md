# Manager Screens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the three primary Manager screens (Dashboard, Visits list, Visit detail) on top of the Claude Design foundation, with full visual fidelity and deterministic placeholders filling data gaps.

**Architecture:** Four phases shipped in order on top of `claude-design-foundation`. Phase 1 introduces `voice/placeholders.py` (the mock-data helper module), three reusable partials (`avatar`, `call_phase_icon`, `outcome_chip`), and `static/css/screens.css` with the shared primitives. Phases 2–4 each extend one view (call its `*_extras` placeholder helper), append screen-specific CSS to `screens.css`, and rewrite that screen's template. No model changes; no new selectors; existing query params, POST forms, and permissions preserved.

**Tech Stack:** Django 4.2, hand-rolled CSS via design tokens shipped in the foundation, Google Fonts (Nunito + Nunito Sans), Flaticon UIcons filled-rounded family.

**Source spec:** [docs/superpowers/specs/2026-05-26-manager-screens-design.md](../specs/2026-05-26-manager-screens-design.md)

**Builds on:** branch `claude-design-foundation` (commits `54ad473` foundation, `50bef94` h4 fix). The foundation provides: design tokens, icons, `shell.css`, `base.html` shell, and three component partials (`status_pill`, `count_badge`, `stat_card`).

**Design package source files** (still in `/tmp/claude-design/` from the foundation pass; the plan references these for CSS extraction):
- Dashboard: `/tmp/claude-design/sales-assistant-calendar-design-system/project/dashboard.css`
- Visits: `/tmp/claude-design/sales-assistant-calendar-design-system/project/visits-styles.css`
- Visit detail: `/tmp/claude-design/sales-assistant-calendar-design-system/project/visit-detail-styles.css`

If `/tmp/claude-design/` no longer exists at execution time, re-extract the bundle from the Claude Design export. The CSS files are the authoritative visual source.

---

## Conventions

- Working directory is the repo root: `/Users/alex/Code/proj-salesassistant`.
- Django dev server: `python manage.py runserver 0.0.0.0:8003` (per user memory).
- **DO NOT commit per task.** Per the established pattern, work stays uncommitted across all phases; final commit happens in Task 15. The user creates a branch or chooses to continue on `claude-design-foundation` at that step.
- Token substitution rule when extracting CSS from the design package: the foundation removed `--fg-dim` (use `--fg-faint`) and bare `--border` (use `--border-default`). If the lifted CSS references either, substitute during extraction.
- After every file change, run `python manage.py check` to confirm no template-syntax errors.

---

## Phase 1 — Shared primitives

### Task 1: Create `voice/placeholders.py`

**Why:** Every screen consumes placeholder-derived values; the helper module must exist before any view can call it.

**Files:**
- Create: `voice/placeholders.py`

- [ ] **Step 1: Write the complete module**

Save the following as `voice/placeholders.py`:

```python
"""
Deterministic placeholder helpers for the redesigned Manager screens.

Each function returns mock values derived from a record's primary key so the
same record always shows the same numbers across refreshes. The intent is to
ship the full visual UI now and replace placeholders with real selectors as
the data becomes available.

Naming convention: every placeholder function has a docstring identifying the
real source that should eventually replace it. When that source ships, find
the function by name and replace its body — templates do not need to change.
"""

from voice.constants import VisitStatus


# ─────────────────────────────────────────────────────────────────────────────
# Per-record helpers
# ─────────────────────────────────────────────────────────────────────────────


def agent_palette(agent):
    """Return one of 'a'|'b'|'c'|'d' — avatar color slot for an agent.

    Real source: a user-chosen avatar color (no model field exists yet)."""
    return ["a", "b", "c", "d"][agent.id % 4]


def visit_ministats(visit):
    """Return mock post-call analytics for the Visit Detail Post-Call card.

    Real source: sentiment + talk-ratio + objections extraction during
    post-call processing — likely new fields on CallAttempt or a separate
    PostCallAnalytics model."""
    return {
        "sentiment": 60 + (visit.id % 30),
        "sentiment_delta": f"+{2 + (visit.id % 6)}",
        "talk_ratio": 40 + (visit.id % 30),
        "objections": visit.id % 4,
        "champion": ["Weak", "Moderate", "Strong", "Champion"][(visit.id // 3) % 4],
    }


def outcome_chips_for_summary(visit):
    """Return a list of (label, tone) for a Recent Summaries row.

    Real source: LLM extraction of outcome signals from
    visit.post_call_summary."""
    pool = [
        ("WIN SIGNAL", "green"),
        ("NEXT: PROPOSAL", "cream"),
        ("RISK: BUDGET", "rose"),
        ("NEXT: DEMO", "cream"),
        ("CHAMPION: STRONG", "green"),
        ("RISK: COMPETITOR", "rose"),
    ]
    n_chips = 1 + (visit.id % 2)
    start = visit.id % len(pool)
    return [pool[(start + i) % len(pool)] for i in range(n_chips)]


def crm_state(visit):
    """Return 'synced'|'pending'|'error' for the Visits table CRM dot.

    Real source: a `crm_sync_state` enum field on Visit (currently we only
    have boolean visit.crm_synced)."""
    if visit.crm_synced:
        return "synced"
    return "error" if (visit.id % 5) == 0 else "pending"


def agent_success_rate(agent, completed=None, total=None):
    """Return a string like '78%'.

    Uses real ratio when both completed and total are provided; falls back to
    a stable mock derived from agent.id otherwise."""
    if total and total > 0:
        return f"{int(100 * (completed or 0) / total)}%"
    return f"{55 + (agent.id % 35)}%"


def agent_readiness_bars(agent_card):
    """Return a list of 8 color tokens for the agent-readiness bar-stack.

    Maps the agent's visits (passed in agent_card['visits']) onto colors:
    COMPLETE → 'zinc-950', anything else (PLANNED, PRE_CALL_DONE, IN_PROGRESS,
    POST_CALL_DONE) → 'cyan-100', pads to 8 slots with 'zinc-200' (empty).

    Note: the design includes a 'rose-100' (cancelled) state but our VisitStatus
    enum has no CANCELLED value yet, so cancelled bars never appear here. When
    CANCELLED is added to the enum, extend the branch below."""
    bars = []
    for visit in (agent_card.get("visits") or [])[:8]:
        status = getattr(visit, "status", None)
        if status == VisitStatus.COMPLETE:
            bars.append("zinc-950")
        else:
            bars.append("cyan-100")
    while len(bars) < 8:
        bars.append("zinc-200")
    return bars


def visit_id_code(visit):
    """Return a display code like 'SA-000412' for a Visit.

    Real source: a `display_code` field on Visit, or a dedicated formatter."""
    return f"SA-{visit.id:06d}"


# ─────────────────────────────────────────────────────────────────────────────
# Dashboard
# ─────────────────────────────────────────────────────────────────────────────


def dashboard_extras(context):
    """Mutate the SuperuserDashboardView context dict in place.

    Requires upstream context keys: today, visit_summary, agent_cards (list of
    dicts from get_agent_readiness), weekly, recent_summaries (queryset),
    next_visit, next_visit_minutes, todays_visits (queryset)."""
    today = context["today"]
    context["today_date_str"] = today.strftime("%A, %B %-d, %Y")
    context["week_label"] = f"Week {today.isocalendar()[1]}"

    # Precomputed "of N" secondary strings for the stat cards (Django template
    # filters can't easily produce this).
    summary = context["visit_summary"]
    context["stat_secondary_total"] = f"of {summary.get('total', 0)}"

    weekly = context["weekly"]
    total_v = weekly.get("total_visits", 0) or 0
    completed_v = weekly.get("completed_visits", 0) or 0
    total_c = weekly.get("total_calls", 0) or 0
    completed_c = weekly.get("completed_calls", 0) or 0
    crm_synced = weekly.get("crm_synced", 0) or 0

    def pct(num, den):
        return int(100 * num / den) if den else 0

    context["weekly_kpis_with_bars"] = [
        {
            "label": "Visit completion",
            "value": f"{completed_v}/{total_v}",
            "pct": pct(completed_v, total_v),
            "sub": f"{pct(completed_v, total_v)}%",
        },
        {
            "label": "Call success",
            "value": f"{completed_c}/{total_c}",
            "pct": pct(completed_c, total_c),
            "sub": f"{pct(completed_c, total_c)}%",
        },
        {
            "label": "CRM sync",
            "value": f"{crm_synced}/{total_v}",
            "pct": pct(crm_synced, total_v),
            "sub": f"{pct(crm_synced, total_v)}%",
        },
    ]

    # Recent summaries — enrich with outcome chips and palette
    context["recent_summaries_with_chips"] = [
        {
            "visit": v,
            "avatar_palette": agent_palette(v.agent),
            "chips": outcome_chips_for_summary(v),
        }
        for v in context["recent_summaries"]
    ]

    # Agent readiness — enrich each card
    context["agent_cards"] = [
        {
            **card,
            "avatar_palette": agent_palette(card["agent"]),
            "bars": agent_readiness_bars(card),
            "success_rate": agent_success_rate(
                card["agent"], card.get("completed", 0), card.get("visit_count", 0)
            ),
        }
        for card in context["agent_cards"]
    ]

    # Next visit chip
    next_visit = context.get("next_visit")
    next_minutes = context.get("next_visit_minutes")
    if next_visit and next_minutes is not None:
        context["next_visit_chip"] = {
            "minutes": next_minutes,
            "label": (
                f"Next visit in {next_minutes} min"
                if next_minutes >= 0
                else "Visit in progress"
            ),
            "agent_name": next_visit.agent.get_full_name() or next_visit.agent.username,
            "agent_avatar_palette": agent_palette(next_visit.agent),
            "time": next_visit.start_time.strftime("%H:%M"),
            "client": next_visit.client.name if next_visit.client else "",
        }
    else:
        context["next_visit_chip"] = None

    # Today's visits — enrich with palette + active flag
    context["todays_visits_enriched"] = [
        {
            "visit": v,
            "avatar_palette": agent_palette(v.agent),
            "is_active": v.status == VisitStatus.IN_PROGRESS,
        }
        for v in context["todays_visits"]
    ]


# ─────────────────────────────────────────────────────────────────────────────
# Visits list
# ─────────────────────────────────────────────────────────────────────────────


def visits_extras(context):
    """Mutate the VisitListView context dict in place.

    Requires upstream context keys: visits (list of dicts with 'visit' key),
    summary, target_date."""
    visits_dicts = context["visits"]
    for vd in visits_dicts:
        v = vd["visit"]
        vd["avatar_palette"] = agent_palette(v.agent)
        vd["crm_state"] = crm_state(v)

    visits = [vd["visit"] for vd in visits_dicts]

    active_visits = [v for v in visits if v.status == VisitStatus.IN_PROGRESS]
    context["active_count"] = len(active_visits)
    context["live_clients"] = [
        (v.client.name if v.client else "—") for v in active_visits[:2]
    ]

    # At risk: visits with a failed call, or planned w/ no methodology
    at_risk = []
    risk_labels = []
    for vd in visits_dicts:
        v = vd["visit"]
        if vd.get("has_failed_call"):
            at_risk.append(v)
            risk_labels.append("call failed")
        elif v.status == VisitStatus.PLANNED and not v.methodology_id:
            at_risk.append(v)
            risk_labels.append("no methodology")
    context["at_risk_count"] = len(at_risk)
    context["at_risk_label"] = ", ".join(sorted(set(risk_labels))) if risk_labels else ""

    total = len(visits)
    synced = sum(1 for v in visits if v.crm_synced)
    context["crm_synced_count"] = synced
    context["crm_synced_total"] = total
    context["crm_synced_pct"] = int(100 * synced / total) if total else 0


# ─────────────────────────────────────────────────────────────────────────────
# Visit detail
# ─────────────────────────────────────────────────────────────────────────────


def _safe_first_contact(client):
    """Return (name, role) for the first contact in client.contacts, else None."""
    if not client:
        return None
    contacts = client.contacts or []
    if not contacts:
        return None
    first = contacts[0]
    if not isinstance(first, dict):
        return None
    name = first.get("name") or first.get("full_name") or "Contact"
    role = first.get("role") or first.get("title") or "Stakeholder"
    return (name, role)


def _initials(name):
    """Return 1-2 initials uppercase from a full name string."""
    if not name:
        return "?"
    parts = [p for p in name.split() if p]
    if not parts:
        return "?"
    if len(parts) == 1:
        return parts[0][:2].upper()
    return (parts[0][0] + parts[-1][0]).upper()


def visit_detail_extras(visit, pre_calls, post_calls, effective_methodology):
    """Return a dict of extras to merge into the VisitDetailView context.

    Pure function. Inputs: the visit, its pre/post call querysets (ordered by
    created_at), and the resolved effective methodology."""
    client = visit.client
    agent = visit.agent

    # ─── kv_strip: 4 columns of meta key/value pairs ───
    last_pre = pre_calls.last() if pre_calls else None
    last_post = post_calls.last() if post_calls else None

    def call_meta(call):
        if not call:
            return ("—", "Not scheduled")
        ts = call.executed_at or call.scheduled_time
        ts_str = ts.strftime("%H:%M") if ts else "—"
        dur = "1:42" if call.status == "COMPLETED" else "—"
        return (call.status.title() if call.status else "Pending", f"{ts_str} · {dur}")

    pre_status, pre_meta = call_meta(last_pre)
    post_status, post_meta = call_meta(last_post)

    kv_strip = [
        {
            "label": "Client",
            "value": client.name if client else "—",
            "sub": client.industry if client else "",
        },
        {
            "label": "CRM Deal",
            "value": visit.crm_deal_id or "—",
            "sub": "Linked" if visit.crm_deal_id else "Unlinked",
        },
        {"label": "Pre-Call", "value": pre_status, "sub": pre_meta},
        {"label": "Post-Call", "value": post_status, "sub": post_meta},
    ]

    # ─── attendees_list ───
    attendees_list = []
    raw = visit.attendees or []
    if raw and isinstance(raw, list):
        for entry in raw:
            if not isinstance(entry, dict):
                continue
            name = entry.get("name") or entry.get("email") or "Attendee"
            role = entry.get("role") or entry.get("title") or "Attendee"
            is_agent = bool(entry.get("is_agent")) or (
                entry.get("email") and agent.email and entry.get("email") == agent.email
            )
            attendees_list.append(
                {
                    "initial": _initials(name),
                    "name": name,
                    "role": role,
                    "is_agent": is_agent,
                }
            )
    if not attendees_list:
        # Placeholder: agent + first client contact if any
        agent_name = agent.get_full_name() or agent.username
        attendees_list.append(
            {
                "initial": _initials(agent_name),
                "name": agent_name,
                "role": "Sales rep",
                "is_agent": True,
            }
        )
        contact = _safe_first_contact(client)
        if contact:
            attendees_list.append(
                {
                    "initial": _initials(contact[0]),
                    "name": contact[0],
                    "role": contact[1],
                    "is_agent": False,
                }
            )

    # ─── pre_call_panel / post_call_panel ───
    def panel_for(call, phase_label):
        if not call:
            return None
        meta_tags = []
        if call.scheduled_time:
            meta_tags.append(call.scheduled_time.strftime("%H:%M scheduled"))
        if call.executed_at:
            meta_tags.append(call.executed_at.strftime("Ran %H:%M"))
        if call.status:
            meta_tags.append(call.status.title())
        snippet = None
        if call.transcript:
            snippet = {
                "ts": "00:24",
                "text": call.transcript[:280].strip(),
            }
        return {
            "title": f"{phase_label} — {call.summary_title or 'Conversation'}",
            "description": call.summary or "Summary pending.",
            "meta_tags": meta_tags,
            "snippet": snippet,
            "has_recording": bool(call.recording_url),
        }

    pre_call_panel = panel_for(last_pre, "Pre-call")
    post_call_panel = panel_for(last_post, "Post-call")
    if pre_call_panel is None:
        pre_call_panel = {
            "title": "Pre-call — not yet run",
            "description": "The pre-meeting AI call has not been scheduled or completed.",
            "meta_tags": [],
            "snippet": None,
            "has_recording": False,
        }
    if post_call_panel is None:
        post_call_panel = {
            "title": "Post-call — not yet run",
            "description": "The post-meeting debrief has not run.",
            "meta_tags": [],
            "snippet": None,
            "has_recording": False,
        }

    post_call_ministats = visit_ministats(visit)

    # ─── client_intel ───
    intel_chip_pool = [
        ("Expanding APAC", "green"),
        ("New CFO", "cream"),
        ("Competitor pilot", "rose"),
        ("Renewal Q3", "green"),
        ("Budget freeze", "rose"),
        ("Champion strong", "green"),
    ]
    n_intel = 3
    start = visit.id % len(intel_chip_pool)
    intel_chips = [
        {"label": intel_chip_pool[(start + i) % len(intel_chip_pool)][0],
         "tone": intel_chip_pool[(start + i) % len(intel_chip_pool)][1]}
        for i in range(n_intel)
    ]
    client_intel_summary = (
        (client.ai_summary if client and client.ai_summary else None)
        or "No client intel summary on file yet. Real summary will be sourced from Client.ai_summary."
    )

    intel_kpis = [
        {"label": "Last contact", "value": "12 days ago"},
        {"label": "Open deals", "value": str(1 + (visit.id % 3))},
        {"label": "ARR", "value": f"${(40 + (visit.id % 60)) * 1000:,}"},
    ]

    # ─── generated_prompts ───
    generated_prompts = []
    if visit.pre_call_prompt:
        generated_prompts.append(
            {"id": "pre", "label": "Pre-call prompt", "body": visit.pre_call_prompt}
        )
    if visit.post_call_prompt:
        generated_prompts.append(
            {"id": "post", "label": "Post-call prompt", "body": visit.post_call_prompt}
        )

    # ─── header metastrip and visit ID ───
    metastrip = {
        "agent_initial": _initials(agent.get_full_name() or agent.username),
        "agent_palette": agent_palette(agent),
        "agent_name": agent.get_full_name() or agent.username,
        "time_range": f"{visit.start_time.strftime('%H:%M')}–{visit.end_time.strftime('%H:%M')}"
        if visit.start_time and visit.end_time
        else "—",
        "date_str": visit.start_time.strftime("%a %b %-d") if visit.start_time else "—",
        "methodology_name": effective_methodology.name if effective_methodology else "—",
        "visit_id_code": visit_id_code(visit),
    }

    return {
        "kv_strip": kv_strip,
        "attendees_list": attendees_list,
        "pre_call_panel": pre_call_panel,
        "post_call_panel": post_call_panel,
        "post_call_ministats": post_call_ministats,
        "client_intel_summary": client_intel_summary,
        "intel_chips": intel_chips,
        "intel_kpis": intel_kpis,
        "generated_prompts": generated_prompts,
        "metastrip": metastrip,
    }
```

- [ ] **Step 2: Verify the module imports cleanly**

```bash
python -c "from voice import placeholders; print(dir(placeholders))" 2>&1 | head -20
```

Expected: a list including `agent_palette`, `dashboard_extras`, `visit_detail_extras`, `visits_extras`, `visit_ministats`, etc., with no ImportError.

- [ ] **Step 3: Verify Django still healthy**

```bash
python manage.py check
```

Expected: `System check identified no issues (0 silenced).`

---

### Task 2: Create the three new partials

**Files:**
- Create: `voice/templates/voice/partials/avatar.html`
- Create: `voice/templates/voice/partials/call_phase_icon.html`
- Create: `voice/templates/voice/partials/outcome_chip.html`

- [ ] **Step 1: Write `voice/templates/voice/partials/avatar.html`**

```django
{% comment %}
Avatar — initial-in-color-circle.

Usage:
  {% include "voice/partials/avatar.html" with initial="AC" palette="a" %}
  {% include "voice/partials/avatar.html" with initial="DC" palette="cyan" size=36 %}

Parameters:
  initial — 1-2 char string, rendered as the centered glyph
  palette — one of: a, b, c, d, cyan (defaults to "a" if omitted)
  size    — pixel size, defaults to 32

Palette → color mapping is defined in screens.css (.av-a etc.).
{% endcomment %}
<span class="av av-{{ palette|default:'a' }}"
      style="width:{{ size|default:32 }}px;height:{{ size|default:32 }}px;font-size:{% if size and size >= 36 %}14px{% else %}12px{% endif %};">{{ initial }}</span>
```

- [ ] **Step 2: Write `voice/templates/voice/partials/call_phase_icon.html`**

```django
{% comment %}
Call-phase icon — circle (pre) or diamond (post), with done/live/todo state.

Usage:
  {% include "voice/partials/call_phase_icon.html" with phase="pre" state="done" %}
  {% include "voice/partials/call_phase_icon.html" with phase="post" state="todo" %}

Parameters:
  phase — "pre" or "post"
  state — "done", "live", or "todo"

Renders a span with the appropriate mask icon from the foundation's icon
sprite. Geometry is defined in screens.css (.call-icon, .call-icon-pre, etc.).
{% endcomment %}
<span class="call-icon call-icon-{{ phase }} call-icon-{{ state }}"></span>
```

- [ ] **Step 3: Write `voice/templates/voice/partials/outcome_chip.html`**

```django
{% comment %}
Outcome chip — title-cased pill with a colored dot.

Used in the Dashboard's Recent Summaries card and Visit Detail's Client Intel
card. Visually identical to a status_pill but typically takes a title-cased
label like "WIN SIGNAL" (display style; the label string is rendered verbatim).

Usage:
  {% include "voice/partials/outcome_chip.html" with label="WIN SIGNAL" tone="green" %}

Parameters:
  label — display string
  tone  — one of: green, cream, rose
{% endcomment %}
<span class="outcome-chip outcome-chip-{{ tone }}">
  <span class="dot"></span>
  <span class="label">{{ label }}</span>
</span>
```

- [ ] **Step 4: Verify Django still healthy**

```bash
python manage.py check
```

Expected: `System check identified no issues (0 silenced).`

---

### Task 3: Create `static/css/screens.css` with shared primitives

**Files:**
- Create: `static/css/screens.css`

This task creates the file and adds the shared-primitive CSS used across all three screens. Per-screen CSS gets appended in Phases 2–4.

- [ ] **Step 1: Create `static/css/screens.css` with shared-primitive rules**

```css
/* ============================================================================
   Sales Assistant — Screen-flavored primitives + per-screen rules.
   Loaded AFTER shell.css. Defines components too screen-specific to live in
   shell.css but reused across multiple screens.
   ============================================================================ */

/* ─────────── Avatar palette ─────────── */
.av {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  color: #fff;
  font-family: var(--font-ui);
  font-weight: 800;
  flex: none;
  user-select: none;
}
.av-a    { background: var(--cyan-500); }
.av-b    { background: var(--orange-500); }
.av-c    { background: var(--zinc-700); }
.av-d    { background: var(--zinc-950); }
.av-cyan { background: var(--cyan-100); color: var(--cyan-600); }

/* ─────────── Outcome chip ─────────── */
.outcome-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  height: 22px;
  padding: 0 10px 0 8px;
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  white-space: nowrap;
}
.outcome-chip .dot {
  width: 6px; height: 6px;
  border-radius: 50%;
  background: currentColor;
  flex: none;
}
.outcome-chip-green { background: var(--green-100); color: var(--green-700); }
.outcome-chip-cream { background: var(--amber-100); color: var(--amber-800); }
.outcome-chip-rose  { background: var(--rose-100);  color: var(--rose-700); }

/* ─────────── Call-phase icon (pre = circle, post = diamond) ─────────── */
.call-icon {
  display: inline-block;
  width: 14px; height: 14px;
  background-color: currentColor;
  -webkit-mask-position: center;
  -webkit-mask-repeat: no-repeat;
  -webkit-mask-size: contain;
  mask-position: center;
  mask-repeat: no-repeat;
  mask-size: contain;
  flex: none;
}
.call-icon-pre.call-icon-done  { -webkit-mask-image: var(--ic-circle-check-mask); mask-image: var(--ic-circle-check-mask); color: var(--green-700); }
.call-icon-pre.call-icon-live  { -webkit-mask-image: var(--ic-circle-check-mask); mask-image: var(--ic-circle-check-mask); color: var(--cyan-500); }
.call-icon-pre.call-icon-todo  { -webkit-mask-image: var(--ic-circle-empty-mask); mask-image: var(--ic-circle-empty-mask); color: var(--zinc-300); }
.call-icon-post.call-icon-done { -webkit-mask-image: var(--ic-diamond-check-mask); mask-image: var(--ic-diamond-check-mask); color: var(--green-700); }
.call-icon-post.call-icon-live { -webkit-mask-image: var(--ic-diamond-check-mask); mask-image: var(--ic-diamond-check-mask); color: var(--cyan-500); }
.call-icon-post.call-icon-todo { -webkit-mask-image: var(--ic-diamond-empty-mask); mask-image: var(--ic-diamond-empty-mask); color: var(--zinc-300); }

/* The foundation's icons.css defines .ic-circle-check, .ic-circle-empty, etc.,
   but they use private mask-image declarations. We re-expose those masks here
   as CSS variables so .call-icon can pick them up. */
:root {
  --ic-circle-check-mask:  url("../icons/circle-check.svg");
  --ic-circle-empty-mask:  url("../icons/circle-empty.svg");
  --ic-diamond-check-mask: url("../icons/diamond-check.svg");
  --ic-diamond-empty-mask: url("../icons/diamond-empty.svg");
}

/* ─────────── CRM dot ─────────── */
.crm-dot {
  display: inline-block;
  width: 8px; height: 8px;
  border-radius: 50%;
  flex: none;
}
.crm-dot-synced  { background: var(--green-700); }
.crm-dot-pending { background: var(--amber-800); }
.crm-dot-error   { background: var(--rose-700); }

/* ─────────── Profile button (header utility row) ─────────── */
.profile-btn {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  height: 40px;
  padding: 3px 12px 3px 3px;
  border-radius: var(--radius-pill);
  background: var(--bg-surface);
  border: 1px solid var(--border-default);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 13px;
  color: var(--fg-strong);
}
.profile-btn .av { width: 30px; height: 30px; font-size: 11px; }
.profile-btn .caret {
  display: inline-block;
  width: 10px; height: 10px;
  -webkit-mask-image: var(--ic-caret-down-mask);
  mask-image: var(--ic-caret-down-mask);
  background: currentColor;
  -webkit-mask-position: center;
  -webkit-mask-repeat: no-repeat;
  -webkit-mask-size: contain;
  mask-position: center;
  mask-repeat: no-repeat;
  mask-size: contain;
  color: var(--fg-muted);
  margin-left: 2px;
}
:root { --ic-caret-down-mask: url("../icons/caret-down.svg"); }

/* ─────────── Segmented toggle (List/Board, Week/Day, etc.) ─────────── */
.toggle {
  display: inline-flex;
  align-items: center;
  background: var(--bg-surface);
  border: 1px solid var(--border-default);
  border-radius: var(--radius-pill);
  padding: 3px;
  height: 36px;
}
.toggle button {
  height: 28px;
  padding: 0 14px;
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 13px;
  color: var(--fg-muted);
}
.toggle button.on { background: var(--zinc-950); color: #fff; }

/* ─────────── Section heading row ─────────── */
.section-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 12px;
  gap: 12px;
}
.section-head h2 {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 20px;
  line-height: 1.1;
  margin: 0;
  color: var(--fg-strong);
}
.section-head .link {
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 13px;
  color: var(--fg-strong);
  text-decoration: underline;
  text-decoration-color: var(--zinc-300);
  text-underline-offset: 3px;
  cursor: pointer;
}
.section-head .link:hover { text-decoration-color: var(--cyan-500); color: var(--cyan-600); }

/* ─────────── Next-visit pulse pill ─────────── */
.next-pill {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  height: 36px;
  padding: 0 14px 0 10px;
  background: var(--cyan-50);
  border: 1px solid #B8EEF6;
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
  color: var(--zinc-700);
  white-space: nowrap;
}
.next-pill .pulse {
  width: 8px; height: 8px;
  border-radius: 50%;
  background: var(--cyan-500);
  box-shadow: 0 0 0 4px rgba(0, 184, 219, 0.18);
  flex: none;
}
.next-pill strong { color: var(--fg-strong); font-weight: 800; }
.next-pill .dim   { color: var(--fg-muted); font-weight: 600; }

/* ─────────── Breadcrumb ─────────── */
.breadcrumb {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-family: var(--font-ui);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg-muted);
}
.breadcrumb a { color: var(--fg-muted); }
.breadcrumb a:hover { color: var(--fg-strong); }
.breadcrumb .sep { color: var(--fg-faint); }
.breadcrumb .cur { color: var(--fg-strong); font-weight: 700; }

/* ─────────── Week chip (header utility row) ─────────── */
.week-chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  height: 36px;
  padding: 0 6px;
  border: 1px solid var(--border-default);
  border-radius: var(--radius-pill);
  background: var(--bg-surface);
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg-strong);
}
.week-chip .lbl { padding: 0 8px; }
.week-chip a {
  width: 28px; height: 28px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  color: var(--fg-strong);
}
.week-chip a:hover { background: var(--zinc-100); }
.week-chip a .ic { width: 14px; height: 14px; }
```

- [ ] **Step 2: Verify the file exists and contains the expected content**

```bash
wc -l static/css/screens.css
grep -c '^\.' static/css/screens.css
```

Expected: ~180 lines; ~25 top-level class selectors.

- [ ] **Step 3: Verify Django can find it**

```bash
python manage.py collectstatic --dry-run --noinput 2>&1 | grep screens.css
```

Expected: one line referencing `css/screens.css`.

---

### Task 4: Load `screens.css` from `base.html`

**Why:** The foundation's `base.html` loads `tokens.css`, `icons.css`, and `shell.css`. We add a fourth `<link>` for `screens.css` so every authenticated page picks up the new primitives.

**Files:**
- Modify: `voice/templates/voice/base.html`

- [ ] **Step 1: Add the link tag**

Open `voice/templates/voice/base.html` and find the existing block:

```django
    <link rel="stylesheet" href="{% static 'css/tokens.css' %}">
    <link rel="stylesheet" href="{% static 'css/icons.css' %}">
    <link rel="stylesheet" href="{% static 'css/shell.css' %}">
```

Append one more line so it becomes:

```django
    <link rel="stylesheet" href="{% static 'css/tokens.css' %}">
    <link rel="stylesheet" href="{% static 'css/icons.css' %}">
    <link rel="stylesheet" href="{% static 'css/shell.css' %}">
    <link rel="stylesheet" href="{% static 'css/screens.css' %}">
```

- [ ] **Step 2: Verify Django still healthy and the stylesheet is served**

```bash
python manage.py check
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8003/static/css/screens.css
```

Expected: check returns `0 silenced`; curl returns `200` (if a dev server is running). If no dev server is running, skip the curl.

---

## Phase 2 — Dashboard

### Task 5: Extend `SuperuserDashboardView` to call `dashboard_extras`

**Files:**
- Modify: `voice/views.py`

- [ ] **Step 1: Locate the view**

Run:

```bash
grep -n "class SuperuserDashboardView" voice/views.py
```

The class spans lines ~366–398 based on prior analysis. The view's `get` method builds the context dict and renders `voice/manager/dashboard.html`.

- [ ] **Step 2: Add the import and the helper call**

At the top of `voice/views.py`, find the existing imports and add:

```python
from voice import placeholders
```

Inside `SuperuserDashboardView`, find the line where the context dict is fully built (right before `return render(...)` or before the context is passed to the template). Add this line so it executes after every other key has been populated:

```python
        placeholders.dashboard_extras(context)
```

The mutation is in-place; no return value to capture. The rest of the view is unchanged.

- [ ] **Step 3: Smoke check**

```bash
python manage.py check
```

Expected: `System check identified no issues (0 silenced).`

If the dev server is running, also visit `http://localhost:8003/dashboard/admin/`. The page should still render exactly as before (the new context keys are added but not yet consumed by the template).

---

### Task 6: Append dashboard-specific CSS to `screens.css`

**Why:** The Dashboard template (Task 7) needs CSS for: Needs Attention card, agent readiness grid + cards, the 60/40 split, recent summaries rows, KPI bars, the datestrip placeholder, and the today-timeline table treatment.

**Files:**
- Modify: `static/css/screens.css` (append)

Source: `/tmp/claude-design/sales-assistant-calendar-design-system/project/dashboard.css`. The plan extracts logically rather than line-by-line — copy the listed selectors, perform substitutions, then append.

- [ ] **Step 1: Append the following CSS block to `static/css/screens.css`**

```css

/* ============================================================================
   Dashboard-specific rules
   ============================================================================ */

/* ─── Needs Attention card ─── */
.needs {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  overflow: hidden;
}
.needs .ne-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 14px 20px;
  border-bottom: 1px solid var(--border-hairline);
}
.needs .ne-head .ttl {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--fg-muted);
  display: flex;
  align-items: center;
  gap: 8px;
}
.needs .ne-head .when {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--fg-muted);
}
.alert-row {
  display: grid;
  grid-template-columns: 24px 1fr auto;
  align-items: center;
  gap: 14px;
  padding: 10px 20px;
  min-height: 48px;
  border-bottom: 1px solid var(--border-hairline);
}
.alert-row:last-child { border-bottom: none; }
.alert-row .ic-wrap {
  width: 24px; height: 24px;
  border-radius: 50%;
  background: var(--amber-100);
  color: var(--amber-800);
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.alert-row .ic-wrap .ic { width: 12px; height: 12px; }
.alert-row .lead {
  font-family: var(--font-tile);
  font-weight: 700;
  font-size: 13px;
  color: var(--fg-strong);
}
.alert-row .meta {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 11px;
  color: var(--fg-muted);
}
.alert-row .cta {
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 13px;
  color: var(--cyan-600);
  white-space: nowrap;
}

/* ─── Stat row grid for Dashboard (4 cols) ─── */
.stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }

/* ─── Agent readiness grid ─── */
.agents { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; }
.agent {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  padding: 24px;
  display: flex;
  flex-direction: column;
  gap: 18px;
}
.agent .top { display: flex; align-items: center; gap: 12px; }
.agent .who { display: flex; flex-direction: column; gap: 5px; min-width: 0; flex: 1; }
.agent .who .nm {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 16px;
  line-height: 1;
  color: var(--fg-strong);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.agent .who .meth {
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
  color: var(--fg-muted);
  line-height: 1;
}
.agent .bars { display: flex; gap: 4px; }
.agent .bars span {
  height: 18px;
  flex: 1;
  border-radius: 4px;
  background: var(--zinc-200);
}
.agent .bars span.b-cyan { background: var(--cyan-100); }
.agent .bars span.b-zinc { background: var(--zinc-950); }
.agent .bars span.b-rose { background: var(--rose-100); }
.agent .footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
}
.agent .footer .lbl {
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--fg-muted);
}
.agent .footer .success {
  color: var(--fg-strong);
  font-feature-settings: 'tnum';
}

/* ─── 60/40 split + cards ─── */
.split { display: grid; grid-template-columns: 60% 40%; gap: 16px; }
.split > .card { display: flex; flex-direction: column; }

/* ─── Recent summaries ─── */
.summaries { display: flex; flex-direction: column; }
.summary {
  display: grid;
  grid-template-columns: 32px 1fr;
  gap: 14px;
  padding: 16px 0;
  border-top: 1px solid var(--border-hairline);
}
.summary:first-child { border-top: none; padding-top: 4px; }
.summary .body { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.summary .head {
  display: flex;
  align-items: center;
  gap: 8px;
  font-family: var(--font-ui);
  font-size: 13px;
  color: var(--fg-strong);
  font-weight: 800;
}
.summary .head .arrow {
  width: 12px; height: 12px;
  background: var(--fg-faint);
  -webkit-mask-image: url("../icons/angle-right.svg");
  mask-image: url("../icons/angle-right.svg");
  -webkit-mask-size: contain;
  mask-size: contain;
  -webkit-mask-repeat: no-repeat;
  mask-repeat: no-repeat;
}
.summary .head .acct { font-weight: 700; }
.summary .head .when {
  margin-left: auto;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--fg-muted);
}
.summary .txt {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  line-height: 1.45;
  color: var(--fg);
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.summary .chips { display: flex; gap: 6px; flex-wrap: wrap; }

/* ─── KPI block (This Week card) ─── */
.kpis { display: flex; flex-direction: column; gap: 16px; }
.kpi { display: flex; flex-direction: column; gap: 8px; }
.kpi .row { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; }
.kpi .row .l {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--fg-muted);
}
.kpi .row .r {
  font-family: var(--font-ui);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg-muted);
  font-feature-settings: 'tnum';
}
.kpi .row .r .v { font-weight: 800; color: var(--fg-strong); font-size: 14px; }
.kpi .bar {
  height: 8px;
  background: var(--zinc-100);
  border-radius: var(--radius-pill);
  overflow: hidden;
}
.kpi .bar > span {
  display: block;
  height: 100%;
  background: var(--cyan-500);
  border-radius: var(--radius-pill);
}
.kpi .sub {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--fg-muted);
  font-feature-settings: 'tnum';
}

/* Date strip kept in markup for future activation; hidden for now */
.datestrip { display: none; }

/* ─── Today's Timeline table (variant of .tbl) ─── */
.timeline-row.active { background: var(--bg-tint); }
.timeline-row .time-cell .time {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 13px;
  color: var(--fg-strong);
}
.timeline-row .time-cell .marks {
  display: flex;
  gap: 6px;
  margin-top: 4px;
  align-items: center;
}
.timeline-row .agent-cell {
  display: flex;
  align-items: center;
  gap: 10px;
}
.timeline-row .agent-cell .av { width: 28px; height: 28px; font-size: 11px; }
.timeline-row .client-cell .industry {
  font-size: 12px;
  color: var(--fg-muted);
  margin-top: 2px;
}
.timeline-row .meth-cell .method-pill {
  display: inline-flex;
  align-items: center;
  height: 22px;
  padding: 0 10px;
  border: 1px solid var(--border-default);
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 11px;
  color: var(--fg-strong);
  background: var(--bg-surface);
}
.timeline-row .kebab-btn {
  width: 28px; height: 28px;
  border-radius: 50%;
  border: 1px solid transparent;
  background: transparent;
  color: var(--fg-muted);
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.timeline-row .kebab-btn:hover { background: var(--zinc-100); }
.timeline-row .kebab-btn .ic { width: 14px; height: 14px; }
```

- [ ] **Step 2: Verify**

```bash
wc -l static/css/screens.css
python manage.py check
```

Expected: ~480 lines now in screens.css; check passes.

---

### Task 7: Rewrite `voice/templates/voice/manager/dashboard.html`

**Files:**
- Modify: `voice/templates/voice/manager/dashboard.html` (full rewrite)

- [ ] **Step 1: Replace the entire file**

Write `voice/templates/voice/manager/dashboard.html` with this content:

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}Dashboard — Sales Assistant{% endblock %}

{% block display_title %}Dashboard{% endblock %}
{% block display_subtitle %}<div class="sub">{{ today_date_str }}</div>{% endblock %}

{% block header_filters %}
<div class="filters">
    <button type="button" class="on">Today</button>
    <button type="button">This week</button>
    <button type="button">All</button>
    <button type="button">At risk</button>
</div>
{% endblock %}

{% block header_actions %}
{% if next_visit_chip %}
<span class="next-pill">
    <span class="pulse"></span>
    <strong>{{ next_visit_chip.label }}</strong>
    <span class="dim">· {{ next_visit_chip.client }} · {{ next_visit_chip.time }}</span>
</span>
{% endif %}
<a href="{% url 'voice:visit_list' %}" class="btn btn-primary"><span class="ic ic-plus ic-14"></span> New visit</a>
{% endblock %}

{% block content %}

{# ─── Needs Attention ─── #}
{% if action_items %}
<div class="needs">
    <div class="ne-head">
        <div class="ttl">
            Needs Attention
            {% include "voice/partials/count_badge.html" with count=action_items|length %}
        </div>
        <div class="when">Updated just now</div>
    </div>
    {% for item in action_items %}
    <div class="alert-row">
        <div class="ic-wrap"><span class="ic ic-clock"></span></div>
        <div class="body">
            <div class="lead">{{ item.message }}</div>
            <div class="meta">{{ item.type|title }} · {{ item.severity|title }}</div>
        </div>
        {% if item.visit_id %}<a class="cta" href="{% url 'voice:visit_detail' visit_id=item.visit_id %}">View →</a>{% endif %}
    </div>
    {% endfor %}
</div>
{% endif %}

{# ─── Stat row ─── #}
<div class="stats">
    {% include "voice/partials/stat_card.html" with label="Active" value=visit_summary.in_progress tone="cyan" %}
    {% include "voice/partials/stat_card.html" with label="Complete today" value=visit_summary.complete %}
    {% include "voice/partials/stat_card.html" with label="Pre-call done" value=visit_summary.pre_call_done secondary=stat_secondary_total %}
    {% include "voice/partials/stat_card.html" with label="Post-call done" value=visit_summary.post_call_done secondary=stat_secondary_total %}
</div>

{# ─── Agent Readiness ─── #}
<div>
    <div class="section-head"><h2>Agent Readiness</h2></div>
    <div class="agents">
        {% for card in agent_cards %}
        <div class="agent">
            <div class="top">
                {% include "voice/partials/avatar.html" with initial=card.agent.username|first|upper palette=card.avatar_palette size=36 %}
                <div class="who">
                    <div class="nm">{{ card.agent.get_full_name|default:card.agent.username }}</div>
                    <div class="meth">{{ card.methodology.name|default:"No methodology" }}</div>
                </div>
                {% if card.status == "pending" %}{% include "voice/partials/status_pill.html" with variant="cyan-filled" label="Live" %}
                {% elif card.status == "done" or card.status == "good" %}{% include "voice/partials/status_pill.html" with variant="green" label="Ready" %}
                {% elif card.status == "error" %}{% include "voice/partials/status_pill.html" with variant="rose" label="Issue" %}
                {% else %}{% include "voice/partials/status_pill.html" with variant="cream" label="Idle" %}{% endif %}
            </div>
            <div class="bars">
                {% for color in card.bars %}<span class="b-{{ color|slice:":4" }}"></span>{% endfor %}
            </div>
            <div class="footer">
                <span class="lbl">Today</span>
                <span class="success">{{ card.visit_count|default:0 }} visits · {{ card.success_rate }} success</span>
            </div>
        </div>
        {% empty %}
        <div class="card" style="grid-column: 1 / -1;">
            <p class="t-body" style="margin:0;color:var(--fg-muted);">No agents on file.</p>
        </div>
        {% endfor %}
    </div>
</div>

{# ─── 60/40 split ─── #}
<div class="split">
    {# Left: Recent Summaries #}
    <div class="card">
        <div class="section-head"><h2>Recent Summaries</h2><a class="link" href="{% url 'voice:visit_list' %}">View all</a></div>
        <div class="summaries">
            {% for s in recent_summaries_with_chips %}
            <div class="summary">
                {% include "voice/partials/avatar.html" with initial=s.visit.agent.username|first|upper palette=s.avatar_palette %}
                <div class="body">
                    <div class="head">
                        <span>{{ s.visit.agent.get_full_name|default:s.visit.agent.username }}</span>
                        <span class="arrow"></span>
                        <span class="acct">{{ s.visit.client.name|default:"—" }}</span>
                        <span class="when">{{ s.visit.end_time|date:"D H:i" }}</span>
                    </div>
                    <div class="txt">{{ s.visit.post_call_summary|default:"Summary pending." }}</div>
                    <div class="chips">
                        {% for chip in s.chips %}{% include "voice/partials/outcome_chip.html" with label=chip.0 tone=chip.1 %}{% endfor %}
                    </div>
                </div>
            </div>
            {% empty %}
            <p class="t-body" style="margin:0;color:var(--fg-muted);">No recent summaries yet.</p>
            {% endfor %}
        </div>
    </div>

    {# Right: This Week #}
    <div class="card">
        <div class="section-head"><h2>This Week</h2><span class="t-caption">{{ weekly.week_start|date:"M j" }} – {{ weekly.week_end|date:"M j" }}</span></div>
        <div class="kpis">
            {% for k in weekly_kpis_with_bars %}
            <div class="kpi">
                <div class="row"><span class="l">{{ k.label }}</span><span class="r"><span class="v">{{ k.value }}</span></span></div>
                <div class="bar"><span style="width: {{ k.pct }}%;"></span></div>
                <div class="sub">{{ k.sub }}</div>
            </div>
            {% endfor %}
        </div>
        <div class="datestrip" aria-hidden="true"></div>
    </div>
</div>

{# ─── Today's Timeline ─── #}
<div>
    <div class="section-head"><h2>Today's Timeline</h2></div>
    <table class="tbl">
        <thead>
            <tr>
                <th style="width: 120px;">Time</th>
                <th>Agent</th>
                <th>Client</th>
                <th>Methodology</th>
                <th>Status</th>
                <th style="width: 48px;"></th>
            </tr>
        </thead>
        <tbody>
            {% for tv in todays_visits_enriched %}
            <tr class="timeline-row{% if tv.is_active %} active{% endif %}">
                <td class="time-cell">
                    <div class="time">{{ tv.visit.start_time|date:"H:i" }}–{{ tv.visit.end_time|date:"H:i" }}</div>
                    <div class="marks">
                        {% include "voice/partials/call_phase_icon.html" with phase="pre" state="done" %}
                        {% include "voice/partials/call_phase_icon.html" with phase="post" state="todo" %}
                    </div>
                </td>
                <td class="agent-cell">
                    {% include "voice/partials/avatar.html" with initial=tv.visit.agent.username|first|upper palette=tv.avatar_palette size=28 %}
                    <span>{{ tv.visit.agent.get_full_name|default:tv.visit.agent.username }}</span>
                </td>
                <td class="client-cell">
                    {{ tv.visit.client.name|default:"—" }}
                    <div class="industry">{{ tv.visit.client.industry|default:"" }}</div>
                </td>
                <td class="meth-cell">
                    <span class="method-pill">{{ tv.visit.methodology.name|default:"—" }}</span>
                </td>
                <td>
                    {% if tv.visit.status == "PLANNED" %}{% include "voice/partials/status_pill.html" with variant="cream" label="Planned" %}
                    {% elif tv.visit.status == "PRE_CALL_DONE" %}{% include "voice/partials/status_pill.html" with variant="cyan" label="Pre-Call" %}
                    {% elif tv.visit.status == "IN_PROGRESS" %}{% include "voice/partials/status_pill.html" with variant="cyan-filled" label="Active" %}
                    {% elif tv.visit.status == "POST_CALL_DONE" %}{% include "voice/partials/status_pill.html" with variant="cream" label="Debrief" %}
                    {% elif tv.visit.status == "COMPLETE" %}{% include "voice/partials/status_pill.html" with variant="green" label="Complete" %}
                    {% elif tv.visit.status == "CANCELLED" %}{% include "voice/partials/status_pill.html" with variant="rose" label="Cancelled" %}{% endif %}
                </td>
                <td><a class="kebab-btn" href="{% url 'voice:visit_detail' visit_id=tv.visit.id %}"><span class="ic ic-menu-dots"></span></a></td>
            </tr>
            {% empty %}
            <tr><td colspan="6" style="text-align:center;padding:32px;color:var(--fg-muted);">No visits scheduled today.</td></tr>
            {% endfor %}
        </tbody>
    </table>
</div>

{% endblock %}
```

- [ ] **Step 2: Verify**

```bash
python manage.py check
```

Expected: passes.

- [ ] **Step 3: Smoke check in browser**

If the dev server is running, visit `http://localhost:8003/dashboard/admin/` as a superuser. Verify:
- New shell renders with active sidebar row = Dashboard
- 6 main regions visible: optional Needs Attention card, Stat row, Agent Readiness grid, 60/40 split (Recent Summaries left, This Week right), Today's Timeline table
- Avatars render in cyan/orange/zinc colors per agent
- In-progress timeline row has cyan-50 background
- Console has no JS errors (favicon 404 is fine)

---

## Phase 3 — Visits list

### Task 8: Extend `VisitListView` to call `visits_extras`

**Files:**
- Modify: `voice/views.py`

- [ ] **Step 1: Add the helper call**

In `voice/views.py`, locate `VisitListView` (line ~1247 per prior analysis). After the context dict is fully built and right before `return render(...)`, add:

```python
        placeholders.visits_extras(context)
```

(The `from voice import placeholders` import was added in Task 5.)

- [ ] **Step 2: Smoke check**

```bash
python manage.py check
```

Expected: `System check identified no issues (0 silenced).`

---

### Task 9: Append Visits-specific CSS to `screens.css`

**Files:**
- Modify: `static/css/screens.css` (append)

Source: `/tmp/claude-design/sales-assistant-calendar-design-system/project/visits-styles.css`.

- [ ] **Step 1: Append the following CSS block to `static/css/screens.css`**

```css

/* ============================================================================
   Visits-list-specific rules
   ============================================================================ */

/* ─── Filter bar ─── */
.filterbar {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 0;
  flex-wrap: wrap;
}
.filterbar .fb-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  height: 36px;
  padding: 0 14px;
  background: var(--bg-surface);
  border: 1px solid var(--border-default);
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 13px;
  color: var(--fg-strong);
}
.filterbar .fb-pill select {
  background: transparent;
  border: none;
  font: inherit;
  color: inherit;
  cursor: pointer;
  outline: none;
}
.filterbar .fb-search {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  height: 36px;
  padding: 0 14px;
  background: var(--bg-surface);
  border: 1px solid var(--border-default);
  border-radius: var(--radius-pill);
  flex: 1;
  min-width: 220px;
}
.filterbar .fb-search input {
  border: none;
  background: transparent;
  font: inherit;
  color: var(--fg-strong);
  outline: none;
  flex: 1;
}
.filterbar .fb-count {
  margin-left: auto;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg-muted);
  font-feature-settings: 'tnum';
}

/* ─── Visits table (vtable, variant of .tbl) ─── */
.vtable { width: 100%; }
.vt-row.cancelled td { color: var(--fg-faint); text-decoration: line-through; }
.vt-row .calls { display: inline-flex; gap: 6px; align-items: center; }
.vt-row .meth-pill {
  display: inline-flex;
  align-items: center;
  height: 22px;
  padding: 0 10px;
  border: 1px solid var(--border-default);
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 11px;
  color: var(--fg-strong);
}
.vt-row .crm-cell { display: inline-flex; gap: 6px; align-items: center; font-family: var(--font-tile); font-weight: 600; font-size: 12px; color: var(--fg-muted); }
.vt-foot {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 16px 20px;
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-top: none;
  border-radius: 0 0 var(--radius-lg) var(--radius-lg);
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg-muted);
}
.vt-foot .pager { display: inline-flex; gap: 8px; }

/* ─── Stat card live-dot variant ─── */
.stat-card .livedot {
  position: absolute;
  top: 16px;
  right: 16px;
  width: 8px; height: 8px;
  border-radius: 50%;
  background: var(--cyan-500);
  box-shadow: 0 0 0 4px rgba(0, 184, 219, 0.18);
}
.stat-card { position: relative; }
.stat-card .stat-sub {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--fg-muted);
}
```

- [ ] **Step 2: Verify**

```bash
wc -l static/css/screens.css
python manage.py check
```

Expected: ~570 lines now in screens.css; check passes.

---

### Task 10: Rewrite `voice/templates/voice/manager/visit_list.html`

**Files:**
- Modify: `voice/templates/voice/manager/visit_list.html` (full rewrite)

- [ ] **Step 1: Replace the entire file**

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}Visits — Sales Assistant{% endblock %}

{% block header_utility %}
<div class="toggle">
    <button type="button" class="on">List</button>
    <button type="button">Board</button>
</div>
<button class="icon-btn" type="button" aria-label="Grid view"><span class="ic ic-grid ic-16"></span></button>
<div class="week-chip">
    <a href="?date={{ prev_date|date:'Y-m-d' }}" aria-label="Previous day"><span class="ic ic-angle-left"></span></a>
    <span class="lbl">{{ target_date|date:"D, M j" }}</span>
    <a href="?date={{ next_date|date:'Y-m-d' }}" aria-label="Next day"><span class="ic ic-angle-right"></span></a>
</div>
{% endblock %}

{% block display_title %}Visits{% endblock %}
{% block display_subtitle %}<div class="sub">{{ target_date|date:"l, F j, Y" }}</div>{% endblock %}

{% block header_filters %}
<div class="filters">
    <button type="button" class="{% if not status_filter %}on{% endif %}">All</button>
    <button type="button" class="{% if status_filter == 'PLANNED' %}on{% endif %}">Upcoming</button>
    <button type="button" class="{% if status_filter == 'COMPLETE' %}on{% endif %}">Completed</button>
    <button type="button" class="{% if status_filter == 'CANCELLED' %}on{% endif %}">Cancelled</button>
</div>
{% endblock %}

{% block header_actions %}
<a href="{% url 'voice:visit_list' %}" class="btn btn-primary"><span class="ic ic-plus ic-14"></span> New visit</a>
{% endblock %}

{% block content %}

{# ─── Stat row ─── #}
<div class="stats">
    {% include "voice/partials/stat_card.html" with label="Total today" value=summary.total %}
    <div class="stat-card{% if active_count %} tone-cyan{% endif %}">
        {% if active_count %}<span class="livedot"></span>{% endif %}
        <div class="meta">Active now</div>
        <div class="num">{{ active_count }}</div>
        {% if live_clients %}<div class="stat-sub">{{ live_clients|join:" · " }}</div>{% endif %}
    </div>
    <div class="stat-card{% if at_risk_count %} tone-rose{% endif %}">
        <div class="meta">At risk</div>
        <div class="num">{{ at_risk_count }}</div>
        {% if at_risk_label %}<div class="stat-sub">{{ at_risk_label }}</div>{% endif %}
    </div>
    <div class="stat-card{% if crm_synced_total %} tone-green{% endif %}">
        <div class="meta">CRM synced</div>
        <div class="num">{{ crm_synced_count }}<span class="secondary">/ {{ crm_synced_total }}</span></div>
        <div class="stat-sub">{{ crm_synced_pct }}%</div>
    </div>
</div>

{# ─── Filter bar (GET form) ─── #}
<form method="get" class="filterbar">
    <input type="hidden" name="date" value="{{ target_date|date:'Y-m-d' }}">
    <span class="fb-pill">
        <select name="agent" onchange="this.form.submit()">
            <option value="">All agents</option>
            {% for a in agents %}<option value="{{ a.id }}" {% if agent_filter == a.id|stringformat:'s' %}selected{% endif %}>{{ a.get_full_name|default:a.username }}</option>{% endfor %}
        </select>
    </span>
    <span class="fb-pill">
        <select name="status" onchange="this.form.submit()">
            <option value="">All statuses</option>
            {% for value, label in status_choices %}<option value="{{ value }}" {% if status_filter == value %}selected{% endif %}>{{ label }}</option>{% endfor %}
        </select>
    </span>
    <span class="fb-search">
        <span class="ic ic-search ic-14"></span>
        <input type="search" name="q" placeholder="Search visits…" disabled>
    </span>
    <span class="fb-count">{{ visits|length }} visits</span>
</form>

{# ─── Visits table ─── #}
<table class="tbl vtable">
    <thead>
        <tr>
            <th style="width: 110px;">Time</th>
            <th>Agent</th>
            <th>Client</th>
            <th>Methodology</th>
            <th style="width: 60px;">Calls</th>
            <th style="width: 110px;">Status</th>
            <th style="width: 60px;">CRM</th>
            <th style="width: 48px;"></th>
        </tr>
    </thead>
    <tbody>
        {% for vd in visits %}
        <tr class="vt-row{% if vd.visit.status == 'CANCELLED' %} cancelled{% endif %}">
            <td>{{ vd.visit.start_time|date:"H:i" }}–{{ vd.visit.end_time|date:"H:i" }}</td>
            <td>
                <div style="display:flex;align-items:center;gap:10px;">
                    {% include "voice/partials/avatar.html" with initial=vd.visit.agent.username|first|upper palette=vd.avatar_palette size=28 %}
                    <span>{{ vd.visit.agent.get_full_name|default:vd.visit.agent.username }}</span>
                </div>
            </td>
            <td>
                {{ vd.visit.client.name|default:"—" }}
                <span class="meta">{{ vd.visit.client.industry|default:"" }}</span>
            </td>
            <td><span class="meth-pill">{{ vd.visit.methodology.name|default:"—" }}</span></td>
            <td>
                <span class="calls">
                    {% if vd.pre_call_done %}{% include "voice/partials/call_phase_icon.html" with phase="pre" state="done" %}{% else %}{% include "voice/partials/call_phase_icon.html" with phase="pre" state="todo" %}{% endif %}
                    {% if vd.post_call_done %}{% include "voice/partials/call_phase_icon.html" with phase="post" state="done" %}{% else %}{% include "voice/partials/call_phase_icon.html" with phase="post" state="todo" %}{% endif %}
                </span>
            </td>
            <td>
                {% if vd.visit.status == "PLANNED" %}{% include "voice/partials/status_pill.html" with variant="cream" label="Planned" %}
                {% elif vd.visit.status == "PRE_CALL_DONE" %}{% include "voice/partials/status_pill.html" with variant="cyan" label="Pre-Call" %}
                {% elif vd.visit.status == "IN_PROGRESS" %}{% include "voice/partials/status_pill.html" with variant="cyan-filled" label="Active" %}
                {% elif vd.visit.status == "POST_CALL_DONE" %}{% include "voice/partials/status_pill.html" with variant="cream" label="Debrief" %}
                {% elif vd.visit.status == "COMPLETE" %}{% include "voice/partials/status_pill.html" with variant="green" label="Complete" %}
                {% elif vd.visit.status == "CANCELLED" %}{% include "voice/partials/status_pill.html" with variant="rose" label="Cancelled" %}{% endif %}
            </td>
            <td><span class="crm-cell"><span class="crm-dot crm-dot-{{ vd.crm_state }}"></span><span>{{ vd.crm_state|title }}</span></span></td>
            <td><a href="{% url 'voice:visit_detail' visit_id=vd.visit.id %}" class="icon-btn" style="width:28px;height:28px;border:none;background:transparent;"><span class="ic ic-menu-dots ic-14"></span></a></td>
        </tr>
        {% empty %}
        <tr><td colspan="8" style="text-align:center;padding:32px;color:var(--fg-muted);">No visits for this date.</td></tr>
        {% endfor %}
    </tbody>
</table>
<div class="vt-foot">
    <div>Showing {{ visits|length }} visits for {{ target_date|date:"M j" }}</div>
    <div class="pager">
        <a href="?date={{ prev_date|date:'Y-m-d' }}" class="btn btn-secondary">← Previous day</a>
        <a href="?date={{ next_date|date:'Y-m-d' }}" class="btn btn-secondary">Next day →</a>
    </div>
</div>

{% endblock %}
```

- [ ] **Step 2: Verify**

```bash
python manage.py check
```

Expected: passes.

- [ ] **Step 3: Smoke check in browser**

Visit `http://localhost:8003/manager/visits/` as a superuser. Verify:
- 4-column stat row with Active-now live-dot if any visit is in progress
- Filter bar with Agent and Status dropdowns
- Table with avatars, methodology pills, call icons, status pills, CRM dots
- Cancelled rows are strikethrough
- Date pagination buttons in footer

---

## Phase 4 — Visit Detail

### Task 11: Extend `VisitDetailView` to call `visit_detail_extras`

**Files:**
- Modify: `voice/views.py`

- [ ] **Step 1: Update the view**

In `voice/views.py`, locate `VisitDetailView._build_context` (line ~1319). At the bottom of that function, right before the final `return context`, add:

```python
        context.update(placeholders.visit_detail_extras(
            visit, pre_calls, post_calls, effective_methodology
        ))
```

The function call returns a dict; `context.update()` merges it. The local variables `visit`, `pre_calls`, `post_calls`, and `effective_methodology` are already defined earlier in the function.

- [ ] **Step 2: Smoke check**

```bash
python manage.py check
```

Expected: `System check identified no issues (0 silenced).`

---

### Task 12: Append Visit-Detail-specific CSS to `screens.css`

**Files:**
- Modify: `static/css/screens.css` (append)

Source: `/tmp/claude-design/sales-assistant-calendar-design-system/project/visit-detail-styles.css`.

- [ ] **Step 1: Append the following CSS block to `static/css/screens.css`**

```css

/* ============================================================================
   Visit-detail-specific rules
   ============================================================================ */

/* ─── Metastrip in the page-action row ─── */
.metastrip {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
  margin-top: 8px;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg-muted);
}
.metastrip .who-tag {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 13px;
  color: var(--fg-strong);
}
.metastrip .who-tag .av { width: 22px; height: 22px; font-size: 10px; }
.metastrip .meth {
  display: inline-flex;
  align-items: center;
  height: 22px;
  padding: 0 10px;
  border: 1px solid var(--border-default);
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 11px;
  color: var(--fg-strong);
  background: var(--bg-surface);
}
.metastrip .vid {
  font-family: var(--font-tile);
  font-weight: 600;
  font-feature-settings: 'tnum';
  color: var(--fg-faint);
}

/* ─── Stepper (5-step lifecycle) ─── */
.stepper {
  display: flex;
  align-items: flex-start;
  gap: 0;
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  padding: 24px;
}
.step {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  position: relative;
}
.step + .step::before {
  content: "";
  position: absolute;
  left: -50%;
  top: 16px;
  width: 100%;
  height: 1px;
  background: var(--border-default);
}
.step.done + .step::before,
.step.current::before {
  background: var(--green-700);
}
.step .bubble {
  width: 32px; height: 32px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 1px solid var(--border-default);
  background: var(--bg-surface);
  position: relative;
  z-index: 1;
}
.step.done .bubble {
  background: var(--green-100);
  border-color: var(--green-100);
  color: var(--green-700);
}
.step.done .bubble .ic { width: 16px; height: 16px; }
.step.current .bubble {
  background: var(--cyan-500);
  border-color: var(--cyan-500);
}
.step.current .bubble::after {
  content: "";
  width: 10px; height: 10px;
  border-radius: 50%;
  background: #fff;
}
.step .label {
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
  color: var(--fg-strong);
}
.step.pending .label { color: var(--fg-muted); font-weight: 500; }
.step .ts {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 11px;
  color: var(--fg-muted);
}

/* ─── Detail grid (70/30) ─── */
.detail-grid { display: grid; grid-template-columns: 1fr 320px; gap: 16px; }
.detail-col { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.detail-side { display: flex; flex-direction: column; gap: 16px; position: sticky; top: 24px; align-self: start; }
.dcard {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  padding: 20px;
}
.dcard h3 {
  margin: 0 0 16px;
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 14px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--fg-muted);
}

/* ─── KV strip (4-col meta) ─── */
.kv-strip {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 16px;
}
.kv {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
}
.kv .label {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
}
.kv .value {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 14px;
  color: var(--fg-strong);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.kv .sub {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--fg-muted);
}

/* ─── Attendee pill ─── */
.attendees { display: flex; flex-wrap: wrap; gap: 8px; }
.att {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  height: 36px;
  padding: 0 12px 0 4px;
  background: var(--zinc-50);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
  color: var(--fg-strong);
}
.att .av { width: 28px; height: 28px; font-size: 11px; }
.att .role {
  color: var(--fg-muted);
  font-weight: 500;
  margin-left: 4px;
  padding-left: 8px;
  border-left: 1px solid var(--border-hairline);
}

/* ─── Call panel ─── */
.callpanel {
  display: grid;
  grid-template-columns: 88px 1fr auto;
  gap: 16px;
  align-items: center;
  padding: 12px;
  background: var(--zinc-50);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-md);
}
.callpanel .thumb {
  width: 88px;
  height: 64px;
  background: var(--zinc-200);
  border-radius: var(--radius-sm);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--fg-strong);
}
.callpanel .thumb .ic { width: 24px; height: 24px; }
.callpanel .body { min-width: 0; }
.callpanel .body .title {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 14px;
  color: var(--fg-strong);
}
.callpanel .body .desc {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg);
  margin-top: 4px;
}
.callpanel .body .tags {
  display: flex;
  gap: 8px;
  margin-top: 8px;
  flex-wrap: wrap;
}
.callpanel .body .tag {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 11px;
  color: var(--fg-muted);
}
.callpanel .replay {
  height: 32px;
  padding: 0 12px;
  border-radius: var(--radius-pill);
  background: var(--bg-surface);
  border: 1px solid var(--border-default);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
  color: var(--fg-strong);
}
.snippet {
  margin-top: 12px;
  padding: 12px;
  background: var(--bg-tint);
  border-left: 3px solid var(--cyan-500);
  border-radius: var(--radius-sm);
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg);
  line-height: 1.5;
}
.snippet .ts {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 11px;
  color: var(--cyan-600);
  margin-right: 8px;
}

/* ─── Ministats (post-call 4-up) ─── */
.ministats {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 12px;
  margin-top: 16px;
}
.ministat {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-md);
  padding: 12px;
}
.ministat .l {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
}
.ministat .v {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 20px;
  color: var(--fg-strong);
  margin-top: 6px;
  font-feature-settings: 'tnum';
}
.ministat .v .delta {
  font-family: var(--font-tile);
  font-weight: 700;
  font-size: 12px;
  color: var(--green-700);
  margin-left: 4px;
}

/* ─── Manager notes form (right rail) ─── */
.notes textarea {
  width: 100%;
  min-height: 120px;
  padding: 10px 12px;
  border: 1px solid var(--border-default);
  border-radius: var(--radius-md);
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg-strong);
  background: var(--bg-surface);
  resize: vertical;
}
.notes textarea:focus { outline: none; border-color: var(--focus-ring); }
.notes .fieldrow { margin-top: 12px; }
.notes select {
  width: 100%;
  height: 36px;
  padding: 0 12px;
  border: 1px solid var(--border-default);
  border-radius: var(--radius-md);
  background: var(--bg-surface);
  font-family: var(--font-ui);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg-strong);
}
.notes .savehint {
  margin-top: 12px;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 11px;
  color: var(--fg-muted);
}

/* ─── Client intel ─── */
.intel-summary {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg);
  line-height: 1.5;
}
.intel-chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 12px; }
.kpi-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-top: 16px;
  padding-top: 16px;
  border-top: 1px solid var(--border-hairline);
}
.kpi-list .row {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
}
.kpi-list .row .l {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
}
.kpi-list .row .v {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 13px;
  color: var(--fg-strong);
}

/* ─── Generated prompts ─── */
.prompt-row {
  border-top: 1px solid var(--border-hairline);
  padding: 12px 0;
}
.prompt-row:first-child { border-top: none; padding-top: 0; }
.prompt-row .head {
  display: flex;
  align-items: center;
  gap: 8px;
  cursor: pointer;
}
.prompt-row .kind {
  height: 20px;
  padding: 0 8px;
  background: var(--zinc-100);
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--fg-strong);
  display: inline-flex;
  align-items: center;
}
.prompt-row .lbl {
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 13px;
  color: var(--fg-strong);
  flex: 1;
}
.prompt-row .copy {
  background: transparent;
  border: 1px solid var(--border-default);
  border-radius: var(--radius-pill);
  padding: 4px 10px;
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 11px;
  color: var(--fg-strong);
}
.prompt-row pre {
  margin: 8px 0 0;
  padding: 12px;
  background: var(--zinc-50);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-md);
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--fg);
  white-space: pre-wrap;
  word-break: break-word;
}
```

- [ ] **Step 2: Verify**

```bash
wc -l static/css/screens.css
python manage.py check
```

Expected: ~870 lines now in screens.css; check passes.

---

### Task 13: Rewrite `voice/templates/voice/manager/visit_detail.html`

**Files:**
- Modify: `voice/templates/voice/manager/visit_detail.html` (full rewrite)

- [ ] **Step 1: Replace the entire file**

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}{{ visit.client.name|default:"Visit" }} — Sales Assistant{% endblock %}

{% block header_utility %}
<nav class="breadcrumb">
    <a href="{% url 'voice:visit_list' %}">Visits</a>
    <span class="sep">/</span>
    <span>{{ visit.start_time|date:"M j" }}</span>
    <span class="sep">/</span>
    <span class="cur">{{ visit.client.name|default:"Visit" }}</span>
</nav>
{% endblock %}

{% block display_title %}{{ visit.client.name|default:"Untitled visit" }}{% endblock %}

{% block display_subtitle %}
<div class="metastrip">
    <span class="who-tag">
        {% include "voice/partials/avatar.html" with initial=metastrip.agent_initial palette=metastrip.agent_palette size=22 %}
        {{ metastrip.agent_name }}
    </span>
    <span>·</span>
    <span>{{ metastrip.date_str }}, {{ metastrip.time_range }}</span>
    <span>·</span>
    <span class="meth">{{ metastrip.methodology_name }}</span>
    <span>·</span>
    <span class="vid">{{ metastrip.visit_id_code }}</span>
</div>
{% endblock %}

{% block header_actions %}
{% if visit.client.crm_id %}<a href="#" class="btn btn-secondary">Open in CRM</a>{% endif %}
<button type="button" class="btn btn-secondary">Share</button>
<button type="button" class="icon-btn" aria-label="More"><span class="ic ic-menu-dots ic-16"></span></button>
{% endblock %}

{% block content %}

{# ─── Stepper ─── #}
<div class="stepper">
    {% for step in steps %}
    <div class="step {% if step.done %}done{% elif step.active %}current{% else %}pending{% endif %}">
        <span class="bubble">{% if step.done %}<span class="ic ic-check"></span>{% endif %}</span>
        <span class="label">{{ step.label }}</span>
    </div>
    {% endfor %}
</div>

{# ─── 70/30 detail grid ─── #}
<div class="detail-grid">
    <div class="detail-col">

        {# Meta card #}
        <div class="dcard">
            <div class="kv-strip">
                {% for kv in kv_strip %}
                <div class="kv">
                    <div class="label">{{ kv.label }}</div>
                    <div class="value">{{ kv.value }}</div>
                    {% if kv.sub %}<div class="sub">{{ kv.sub }}</div>{% endif %}
                </div>
                {% endfor %}
            </div>
        </div>

        {# Attendees #}
        <div class="dcard">
            <h3>Attendees</h3>
            <div class="attendees">
                {% for a in attendees_list %}
                <div class="att">
                    {% include "voice/partials/avatar.html" with initial=a.initial palette="cyan" size=28 %}
                    <span>{{ a.name }}</span>
                    <span class="role">{{ a.role }}</span>
                </div>
                {% endfor %}
            </div>
        </div>

        {# Pre-call #}
        <div class="dcard">
            <h3>Pre-call</h3>
            <div class="callpanel">
                <div class="thumb"><span class="ic ic-comment-alt-dots"></span></div>
                <div class="body">
                    <div class="title">{{ pre_call_panel.title }}</div>
                    <div class="desc">{{ pre_call_panel.description }}</div>
                    <div class="tags">
                        {% for tag in pre_call_panel.meta_tags %}<span class="tag">{{ tag }}</span>{% endfor %}
                    </div>
                </div>
                {% if pre_call_panel.has_recording %}<button type="button" class="replay">Replay</button>{% endif %}
            </div>
            {% if pre_call_panel.snippet %}
            <div class="snippet">
                <span class="ts">{{ pre_call_panel.snippet.ts }}</span>{{ pre_call_panel.snippet.text }}
            </div>
            {% endif %}
        </div>

        {# Post-call #}
        <div class="dcard">
            <h3>Post-call</h3>
            <div class="callpanel">
                <div class="thumb"><span class="ic ic-comment-alt-dots"></span></div>
                <div class="body">
                    <div class="title">{{ post_call_panel.title }}</div>
                    <div class="desc">{{ post_call_panel.description }}</div>
                    <div class="tags">
                        {% for tag in post_call_panel.meta_tags %}<span class="tag">{{ tag }}</span>{% endfor %}
                    </div>
                </div>
                {% if post_call_panel.has_recording %}<button type="button" class="replay">Replay</button>{% endif %}
            </div>
            <div class="ministats">
                <div class="ministat"><div class="l">Sentiment</div><div class="v">{{ post_call_ministats.sentiment }}%<span class="delta">{{ post_call_ministats.sentiment_delta }}</span></div></div>
                <div class="ministat"><div class="l">Talk ratio</div><div class="v">{{ post_call_ministats.talk_ratio }}%</div></div>
                <div class="ministat"><div class="l">Objections</div><div class="v">{{ post_call_ministats.objections }}</div></div>
                <div class="ministat"><div class="l">Champion</div><div class="v" style="font-size:14px;">{{ post_call_ministats.champion }}</div></div>
            </div>
        </div>

        {# Debrief #}
        {% if visit.post_call_summary %}
        <div class="dcard">
            <h3>Debrief Summary</h3>
            <p class="t-body" style="margin:0;line-height:1.5;color:var(--fg);">{{ visit.post_call_summary|linebreaksbr }}</p>
        </div>
        {% endif %}
    </div>

    <div class="detail-side">

        {# Manager Notes #}
        <div class="dcard notes">
            <h3>Manager Notes</h3>
            <form method="post">
                {% csrf_token %}
                <textarea name="manager_notes" placeholder="Notes about this visit…">{{ form.manager_notes.value|default:"" }}</textarea>
                {% if form.methodology %}
                <div class="fieldrow">
                    <label class="t-meta" style="display:block;margin-bottom:6px;">Methodology override</label>
                    {{ form.methodology }}
                </div>
                {% endif %}
                <div class="fieldrow">
                    <button type="submit" class="btn btn-primary" style="width:100%;justify-content:center;">Save</button>
                </div>
                <div class="savehint">Changes affect future pre/post-call prompts.</div>
            </form>
        </div>

        {# Client Intel #}
        <div class="dcard">
            <h3>Client Intel</h3>
            <p class="intel-summary">{{ client_intel_summary }}</p>
            <div class="intel-chips">
                {% for chip in intel_chips %}{% include "voice/partials/outcome_chip.html" with label=chip.label tone=chip.tone %}{% endfor %}
            </div>
            <div class="kpi-list">
                {% for k in intel_kpis %}
                <div class="row"><span class="l">{{ k.label }}</span><span class="v">{{ k.value }}</span></div>
                {% endfor %}
            </div>
        </div>

        {# Generated Prompts #}
        {% if generated_prompts %}
        <div class="dcard">
            <h3>Generated Prompts</h3>
            {% for p in generated_prompts %}
            <div class="prompt-row">
                <div class="head">
                    <span class="kind">{{ p.id|upper }}</span>
                    <span class="lbl">{{ p.label }}</span>
                    <button type="button" class="copy">Copy</button>
                </div>
                <pre>{{ p.body }}</pre>
            </div>
            {% endfor %}
        </div>
        {% endif %}
    </div>
</div>

{% endblock %}
```

- [ ] **Step 2: Verify**

```bash
python manage.py check
```

Expected: passes.

- [ ] **Step 3: Smoke check in browser**

Visit a real visit's detail page at `http://localhost:8003/manager/visits/<id>/` as a superuser. Verify:
- Breadcrumb in the utility row
- Visit title + metastrip below
- Full 5-step stepper (some done, some pending — depends on the visit's lifecycle state)
- 70/30 layout: meta card, attendees, pre/post-call cards, optional debrief in the left column
- Right rail: manager notes form (POST works), client intel, generated prompts
- Submit the manager notes form and confirm the message flash + persisted value

---

## Task 14: Final cross-cutting smoke verification

**Files:** none.

- [ ] **Step 1: Start dev server (if not already running)**

```bash
python manage.py runserver 0.0.0.0:8003
```

- [ ] **Step 2: Visit all three screens as a superuser**

In a browser, log in as a superuser and walk:
- `/dashboard/admin/` — verify all 6 regions render; agent bar-stack is deterministic across refreshes (same colors each time); active timeline row has cyan-50 background
- `/manager/visits/` — verify stat row; click date pagination; change agent dropdown; observe filtered table
- `/manager/visits/<id>/` — try at least 2 different visits in different lifecycle states (planned vs in-progress vs complete); confirm stepper colors match state; POST the manager notes form

- [ ] **Step 3: Verify static asset health**

```bash
curl -s -o /dev/null -w "%{http_code} %{url_effective}\n" \
  http://localhost:8003/static/css/tokens.css \
  http://localhost:8003/static/css/shell.css \
  http://localhost:8003/static/css/icons.css \
  http://localhost:8003/static/css/screens.css \
  http://localhost:8003/static/icons/diamond-check.svg
```

All five should return `200`.

- [ ] **Step 4: Stop the dev server**

Ctrl+C.

No commit yet — Task 15 handles that.

---

## Task 15: Branch and commit

The user previously chose: stay uncommitted during phases, then commit on a separate branch at the end. Follow the same pattern.

**Files:** none staged yet.

- [ ] **Step 1: Inspect what's about to be staged**

```bash
git status --short
```

Confirm the working tree has the new screens.css, the three new partials, placeholders.py, the modified base.html, modified manager templates (dashboard/visit_list/visit_detail), and modified voice/views.py. Pre-existing unrelated user WIP (Python files, agent/manager templates) should NOT be staged.

- [ ] **Step 2: Create branch (if not already on `manager-screens`)**

Run:

```bash
git rev-parse --abbrev-ref HEAD
```

If currently on `claude-design-foundation` (the foundation branch), branch off from it:

```bash
git checkout -b manager-screens
```

If currently on `main` or a different branch, ask the user before continuing — the new screens depend on the foundation.

- [ ] **Step 3: Stage only the foundation-relevant files**

```bash
git add static/css/screens.css \
        voice/placeholders.py \
        voice/templates/voice/partials/avatar.html \
        voice/templates/voice/partials/call_phase_icon.html \
        voice/templates/voice/partials/outcome_chip.html \
        voice/templates/voice/base.html \
        voice/templates/voice/manager/dashboard.html \
        voice/templates/voice/manager/visit_list.html \
        voice/templates/voice/manager/visit_detail.html \
        voice/views.py \
        docs/superpowers/plans/2026-05-26-manager-screens.md
```

Verify with `git status --short`. The only `A` (added) and `M` (modified) entries in the "Changes to be committed" section should be the files above.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
Manager screens: Dashboard, Visits, Visit Detail

Implements docs/superpowers/plans/2026-05-26-manager-screens.md.

Phase 1 ships voice/placeholders.py (deterministic placeholder helpers
for elements without backing data yet), three new partials (avatar,
call_phase_icon, outcome_chip), and static/css/screens.css with
shared screen-flavored primitives (outcome chips, call icons, CRM
dots, profile button, toggle, section head, next-visit pill,
breadcrumb, week chip).

Phase 2 (Dashboard) extends SuperuserDashboardView with
dashboard_extras and rewrites manager/dashboard.html into 6 regions:
Needs Attention, stat row, Agent Readiness with 8-tile bar-stack,
60/40 split (Recent Summaries + This Week KPI), and Today's Timeline.

Phase 3 (Visits) extends VisitListView with visits_extras and
rewrites manager/visit_list.html with stat row (Active-now live dot),
GET filter bar, full-width table, and pagination footer.

Phase 4 (Visit Detail) extends VisitDetailView with visit_detail_extras
and rewrites manager/visit_detail.html with breadcrumb header,
metastrip, 5-step stepper, 70/30 grid (meta card, attendees, pre/post
call panels, debrief on left; manager notes form, client intel,
generated prompts on right).

No model changes, no new selectors. Placeholders are derived
deterministically from primary keys and documented inline with
real-source references for follow-up replacement.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Confirm**

```bash
git log --oneline -5
```

Expected: one new commit on top of the foundation branch with the message above.

---

## Out of scope (named so we don't drift)

- Board view (Visits page toggle visual-only)
- Search input on Visits page (visual-only)
- Notifications popover, kebab menus, Share modal (placeholders)
- New visit creation flow (CTAs link to visit_list)
- Replacing placeholders with real data — each docstring names the real source
- Mobile layout
- Empty-state illustrations beyond the existing centered "No X" messages
- Authenticated Sales Agent dashboard / Calendar Sync / Profile (already have their own screens)

## Rollback

`git revert` of the commit produced by Task 15. No database, no service, no environment changes.
