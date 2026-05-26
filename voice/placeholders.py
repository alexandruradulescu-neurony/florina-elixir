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
        {"label": "Last contact", "value": f"{5 + (visit.id % 28)} days ago"},
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
