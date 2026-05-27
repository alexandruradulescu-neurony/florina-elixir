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


def _client_status_badge(client):
    """Return (css_class, label) for the client status badge.

    Returns ('is-new', 'Client nou') / ('is-existing', 'Client existent') / (None, None).
    """
    if not client or not getattr(client, "status", None):
        return (None, None)
    if client.status == "existent":
        return ("is-existing", "Client existent")
    # default to 'nou' for any non-existing value (including the enum default)
    return ("is-new", "Client nou")


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
            full = call.transcript.strip()
            preview = full[:280]
            if len(full) > 280:
                # cut on word boundary so the preview reads cleanly
                cut = preview.rsplit(' ', 1)[0] or preview
                preview = cut.rstrip('.,;:') + '…'
            snippet = {
                "ts": "00:00",
                "preview": preview,
                "full": full,
                "has_more": len(full) > len(preview),
                # legacy key for backward compat (template may still read .text)
                "text": preview,
            }
        return {
            "title": f"{phase_label} — {call.summary_title or 'Conversație'}",
            "description": call.summary or "Sumar în curs de generare.",
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

    # Prefer real Claude analysis from the latest post-call if present
    last_post_with_analysis = None
    for c in (post_calls or []):
        if c.analysis:
            last_post_with_analysis = c
    if last_post_with_analysis:
        a = last_post_with_analysis.analysis
        tr = a.get('talk_ratio') or {}
        post_call_ministats = {
            'sentiment': a.get('sentiment_score', 0),
            'sentiment_delta': a.get('sentiment', 'neutral'),
            'talk_ratio': tr.get('agent', 0),
            'objections': len(a.get('objections_raised') or []),
            'champion': (a.get('champion_strength') or 'unknown').title(),
        }
        post_call_analysis = a
    else:
        post_call_ministats = visit_ministats(visit)
        post_call_analysis = None

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

    # ─── Client status badge (nou / existent) ───
    client_status_class, client_status_label = _client_status_badge(client)

    return {
        "kv_strip": kv_strip,
        "attendees_list": attendees_list,
        "pre_call_panel": pre_call_panel,
        "post_call_panel": post_call_panel,
        "post_call_ministats": post_call_ministats,
        "post_call_analysis": post_call_analysis,
        "client_intel_summary": client_intel_summary,
        "intel_chips": intel_chips,
        "intel_kpis": intel_kpis,
        "generated_prompts": generated_prompts,
        "metastrip": metastrip,
        "client_status_class": client_status_class,
        "client_status_label": client_status_label,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Agents list
# ─────────────────────────────────────────────────────────────────────────────


def agents_extras(context):
    """Mutate the AgentManagementView context dict in place.

    Requires upstream keys: agents (list of dicts with 'agent' key + various
    counts), agent_count, configured_count."""
    enriched = []
    for ad in context["agents"]:
        a = ad["agent"]
        bars = []
        done = ad.get("visits_complete_today", 0) or 0
        scheduled = ad.get("visits_today", 0) or 0
        upcoming = max(0, scheduled - done)
        for _ in range(done):
            if len(bars) < 8:
                bars.append("zinc")
        for _ in range(upcoming):
            if len(bars) < 8:
                bars.append("cyan")
        while len(bars) < 8:
            bars.append("empty")
        if ad.get("call_success_rate") is not None:
            success_pct = int(ad["call_success_rate"])
        else:
            success_pct = 55 + (a.id % 35)
        enriched.append(
            {
                **ad,
                "avatar_palette": agent_palette(a),
                "today_load_bars": bars,
                "load_pct": int(100 * done / scheduled) if scheduled else 0,
                "success_pct": success_pct,
            }
        )
    context["agents"] = enriched

    agent_count = context.get("agent_count", 0) or 0
    context["agents_live_now"] = sum(1 for ad in enriched if ad.get("visits_today"))
    context["agents_avg_success"] = (
        int(sum(ad["success_pct"] for ad in enriched) / agent_count)
        if agent_count
        else 0
    )


# ─────────────────────────────────────────────────────────────────────────────
# Clients list
# ─────────────────────────────────────────────────────────────────────────────


def _strip_domain(domain):
    """Strip http(s):// and www. from a domain string for display."""
    if not domain:
        return ""
    s = str(domain).strip()
    for prefix in ("https://", "http://"):
        if s.lower().startswith(prefix):
            s = s[len(prefix):]
    if s.lower().startswith("www."):
        s = s[4:]
    return s.rstrip("/")


def _relative_ago(dt):
    """Return a human-readable relative-time string ('2h ago', '3d ago', ...).

    Returns '—' if dt is None."""
    from django.utils import timezone
    if not dt:
        return "—"
    delta = timezone.now() - dt
    seconds = int(delta.total_seconds())
    if seconds < 60:
        return "just now"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes}m ago"
    hours = minutes // 60
    if hours < 24:
        return f"{hours}h ago"
    days = hours // 24
    if days < 30:
        return f"{days}d ago"
    months = days // 30
    return f"{months}mo ago"


def clients_extras(context):
    """Mutate the ClientListView context dict in place."""
    enriched = []
    crm_count = 0
    stale_count = 0
    for cd in context["clients"]:
        c = cd["client"]
        has_crm = bool(c.crm_id)
        if has_crm:
            crm_count += 1
        if cd.get("is_stale"):
            stale_count += 1
        enriched.append(
            {
                **cd,
                "domain_short": _strip_domain(c.domain),
                "intel_ai_on": bool(cd.get("has_summary")),
                "intel_crm_on": has_crm,
                "synced_fresh": not cd.get("is_stale"),
                "synced_ago": _relative_ago(c.last_synced_at),
                "last_visit_str": (
                    cd["last_visit"].start_time.strftime("%b %-d")
                    if cd.get("last_visit") and cd["last_visit"].start_time
                    else "—"
                ),
            }
        )
    context["clients"] = enriched
    context["clients_with_crm_count"] = crm_count
    context["clients_stale_count"] = stale_count


# ─────────────────────────────────────────────────────────────────────────────
# Methodologies list
# ─────────────────────────────────────────────────────────────────────────────


def methodologies_extras(context):
    """Mutate the MethodologyListView context dict in place."""
    enriched = []
    pdf_count = 0
    for md in context["methodologies"]:
        m = md["methodology"]
        desc = m.description or ""
        if len(desc) > 120:
            cut = desc[:120].rsplit(" ", 1)[0]
            desc_short = cut + "…"
        else:
            desc_short = desc
        if md.get("has_pdf"):
            pdf_count += 1
        enriched.append(
            {
                **md,
                "desc_short": desc_short,
                "status_label": "Active" if m.is_active else "Inactive",
                "status_tone": "green" if m.is_active else "cream",
            }
        )
    context["methodologies"] = enriched
    context["methodologies_with_pdf_count"] = pdf_count


# ─────────────────────────────────────────────────────────────────────────────
# Agent detail (NEW view)
# ─────────────────────────────────────────────────────────────────────────────


def agent_detail_extras(agent, recent_visits, recent_calls):
    """Return a dict of extras for the AgentDetailView context.

    Pure function. recent_visits is a list/queryset of Visit, recent_calls is
    a list/queryset of CallAttempt."""
    visits_list = list(recent_visits) if recent_visits else []
    calls_list = list(recent_calls) if recent_calls else []

    from django.utils import timezone
    today = timezone.now().date()
    today_visits = [v for v in visits_list if v.start_time and v.start_time.date() == today]
    completed_today = [v for v in today_visits if v.status == VisitStatus.COMPLETE]
    active_now = [v for v in today_visits if v.status == VisitStatus.IN_PROGRESS]

    bars = []
    for v in today_visits[:8]:
        if v.status == VisitStatus.COMPLETE:
            bars.append("zinc")
        elif v.status == VisitStatus.IN_PROGRESS:
            bars.append("cyan")
        else:
            bars.append("cyan")
    while len(bars) < 8:
        bars.append("empty")

    methodology_name = agent.default_methodology.name if agent.default_methodology else "—"
    agent_kv_strip = [
        {"label": "Email", "value": agent.email or "—", "sub": ""},
        {"label": "Phone", "value": agent.phone_number or "—", "sub": ""},
        {"label": "Methodology", "value": methodology_name, "sub": ""},
        {
            "label": "Pipedrive",
            "value": str(agent.pipedrive_user_id) if agent.pipedrive_user_id else "—",
            "sub": "",
        },
    ]

    agent_stat_row = [
        {"label": "Visits today", "value": len(today_visits), "tone": "default"},
        {"label": "Completed", "value": len(completed_today), "tone": "green"},
        {"label": "Active now", "value": len(active_now), "tone": "cyan"},
        {"label": "Success rate", "value": f"{55 + (agent.id % 35)}%", "tone": "default"},
    ]

    recent_visits_enriched = []
    for v in visits_list[:20]:
        recent_visits_enriched.append(
            {
                "visit": v,
                "client_name": v.client.name if v.client else "—",
                "client_industry": v.client.industry if v.client else "",
                "status": v.status,
                "client_palette": agent_palette(v.agent) if v.agent else "a",
            }
        )

    recent_calls_enriched = []
    for c in calls_list[:10]:
        recent_calls_enriched.append(
            {
                "call": c,
                "visit": c.visit,
                "phase": c.phase,
                "status": c.status,
                "executed_at": c.executed_at,
                "ago": _relative_ago(c.executed_at or c.scheduled_time),
            }
        )

    if active_now:
        agent_status_label = "Live"
        agent_status_variant = "cyan-filled"
    elif today_visits and len(completed_today) == len(today_visits):
        agent_status_label = "Ready"
        agent_status_variant = "green"
    elif not agent.phone_number:
        agent_status_label = "No phone"
        agent_status_variant = "rose"
    elif not today_visits:
        agent_status_label = "Idle"
        agent_status_variant = "cream"
    else:
        agent_status_label = "Working"
        agent_status_variant = "cyan"

    config_indicators = [
        {"label": "Phone on file", "on": bool(agent.phone_number)},
        {"label": "Methodology assigned", "on": bool(agent.default_methodology_id)},
        {"label": "Pipedrive linked", "on": bool(agent.pipedrive_user_id)},
    ]

    return {
        "agent_avatar_palette": agent_palette(agent),
        "agent_id_code": f"AG-{agent.id:06d}",
        "agent_kv_strip": agent_kv_strip,
        "agent_stat_row": agent_stat_row,
        "today_load_bars": bars,
        "recent_visits_enriched": recent_visits_enriched,
        "recent_calls_enriched": recent_calls_enriched,
        "agent_status_label": agent_status_label,
        "agent_status_variant": agent_status_variant,
        "config_indicators": config_indicators,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Client detail
# ─────────────────────────────────────────────────────────────────────────────


def client_detail_extras(client_detail):
    """Return a dict of extras to update the ClientDetailView context."""
    client = client_detail.get("client")
    visits = client_detail.get("visits") or []
    agents = client_detail.get("agents") or []
    recent_calls = client_detail.get("recent_calls") or []

    domain_str = _strip_domain(client.domain) if client else ""
    client_kv_strip = [
        {"label": "Industry", "value": (client.industry if client else "—") or "—", "sub": ""},
        {"label": "Domain", "value": domain_str or "—", "sub": ""},
        {"label": "CRM ID", "value": (client.crm_id if client else "—") or "—", "sub": ""},
        {
            "label": "Last Synced",
            "value": _relative_ago(client.last_synced_at) if client else "—",
            "sub": (
                client.last_synced_at.strftime("%b %-d, %H:%M")
                if client and client.last_synced_at
                else ""
            ),
        },
    ]

    completion_rate = client_detail.get("completion_rate", 0) or 0
    client_stat_row = [
        {"label": "Total visits", "value": client_detail.get("total_visits", 0), "tone": "default"},
        {"label": "Completed", "value": client_detail.get("completed_visits", 0), "tone": "green"},
        {"label": "Completion", "value": f"{completion_rate}%", "tone": "cyan"},
        {"label": "Active agents", "value": len(agents), "tone": "default"},
    ]

    agents_enriched = []
    for a in agents:
        agents_enriched.append(
            {
                "agent": a,
                "avatar_palette": agent_palette(a),
                "methodology_name": (
                    a.default_methodology.name if a.default_methodology else "—"
                ),
            }
        )

    visits_enriched = []
    for v in visits:
        visits_enriched.append(
            {
                "visit": v,
                "avatar_palette": agent_palette(v.agent) if v.agent else "a",
                "agent_name": (
                    v.agent.get_full_name() or v.agent.username if v.agent else "—"
                ),
                "methodology_name": v.methodology.name if v.methodology else "—",
            }
        )

    recent_calls_enriched = []
    for c in recent_calls:
        recent_calls_enriched.append(
            {
                "call": c,
                "visit": c.visit,
                "agent_name": (
                    c.visit.agent.get_full_name() or c.visit.agent.username
                    if c.visit and c.visit.agent
                    else "—"
                ),
                "agent_palette": agent_palette(c.visit.agent) if c.visit and c.visit.agent else "a",
                "phase": c.phase,
                "status": c.status,
                "ago": _relative_ago(c.executed_at or c.scheduled_time),
            }
        )

    intel_summary = (
        client.ai_summary
        if client and client.ai_summary
        else "No client intel summary on file yet. AI extraction will populate this when the next sync runs."
    )

    client_status_class, client_status_label = _client_status_badge(client)

    return {
        "client_kv_strip": client_kv_strip,
        "client_stat_row": client_stat_row,
        "agents_enriched": agents_enriched,
        "visits_enriched": visits_enriched,
        "recent_calls_enriched": recent_calls_enriched,
        "client_intel_summary": intel_summary,
        "client_domain_short": domain_str,
        "client_last_synced_ago": _relative_ago(client.last_synced_at) if client else "—",
        "client_status_class": client_status_class,
        "client_status_label": client_status_label,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Calendar
# ─────────────────────────────────────────────────────────────────────────────


def _visit_state(visit):
    """Return the design's event state for a visit: upcoming/completed/cancelled/replanned.

    Real source: when CANCELLED is added to VisitStatus, drop the placeholder
    branches. Until then we fake variety with PK-based rules."""
    if visit.status == VisitStatus.COMPLETE:
        return "completed"
    if (visit.id % 13) == 0:
        return "cancelled"
    if (visit.id % 17) == 0:
        return "replanned"
    return "upcoming"


def _enrich_event(visit, short=False):
    """Return the dict shape consumed by the calendar template's event chip."""
    time_range = "—"
    if visit.start_time and visit.end_time:
        time_range = f"{visit.start_time.strftime('%H:%M')}-{visit.end_time.strftime('%H:%M')}"
    client_name = visit.client.name if visit.client else ""
    raw_title = visit.title or ""
    if client_name and raw_title:
        title = f"{client_name} – {raw_title}"
    else:
        title = client_name or raw_title or "Visit"
    if len(title) > 40:
        title = title[:39] + "…"
    return {
        "visit": visit,
        "state": _visit_state(visit),
        "time_range": time_range,
        "title": title,
        "short": short,
    }


def _build_hour_buckets(visits, default_start=9, default_end=18):
    """Build a list of hour buckets for the Day view.

    Each bucket: {hour: int, hour_label: str, events: list of enriched events}.
    Extends past default_start..default_end if any visit falls outside that
    range."""
    hours_with_events = set()
    for v in visits:
        if v.start_time:
            hours_with_events.add(v.start_time.hour)
    start_hour = min([default_start] + list(hours_with_events))
    end_hour = max([default_end] + list(hours_with_events))
    buckets = []
    for h in range(start_hour, end_hour + 1):
        events = [
            _enrich_event(v, short=False)
            for v in visits
            if v.start_time and v.start_time.hour == h
        ]
        buckets.append(
            {
                "hour": h,
                "hour_label": f"{h:02d}:00",
                "events": events,
            }
        )
    return buckets


def _build_mini_cal_month(target_date):
    """Build a 6×7 month grid for the mini-calendar on Day mode.

    Returns a list of 42 cell dicts: {day_num, iso, in_month, is_today, is_selected}."""
    from datetime import timedelta
    from django.utils import timezone

    today = timezone.now().date()
    first_of_month = target_date.replace(day=1)
    offset = first_of_month.weekday()
    grid_start = first_of_month - timedelta(days=offset)

    cells = []
    for i in range(42):
        d = grid_start + timedelta(days=i)
        cells.append(
            {
                "day_num": d.day,
                "iso": d.isoformat(),
                "in_month": d.month == target_date.month,
                "is_today": d == today,
                "is_selected": d == target_date,
            }
        )
    return cells


def calendar_extras(context):
    """Mutate the VisitCalendarView context dict in place.

    Branches on context['view_mode'] ('week' or 'day'). Required upstream keys:
    target_date, view_mode, and either 'weeks' (week mode) or 'visits_for_day'
    (day mode)."""
    target_date = context["target_date"]
    view_mode = context.get("view_mode", "week")

    context["month_label"] = target_date.strftime("%B %Y")
    if view_mode == "day":
        from django.utils import timezone
        today = timezone.now().date()
        context["nav_label"] = "Today" if target_date == today else target_date.strftime("%A")
    else:
        context["nav_label"] = "This week"

    context.setdefault("status_filter", "all")

    if view_mode == "day":
        visits_for_day = context.get("visits_for_day") or []
        context["hour_buckets"] = _build_hour_buckets(visits_for_day)
        context["month_grid"] = _build_mini_cal_month(target_date)
        context["day_visit_count"] = len(visits_for_day)
    else:
        from django.utils import timezone
        today = timezone.now().date()
        enriched_weeks = []
        for week in context.get("weeks", []):
            days = []
            week_dates = []
            for day in week:
                d_date = day.get("date")
                week_dates.append(d_date)
                events_enriched = [
                    _enrich_event(v, short=True) for v in (day.get("visits") or [])
                ]
                days.append(
                    {
                        **day,
                        "events_enriched": events_enriched,
                        "has_events": bool(events_enriched),
                    }
                )
            is_current_week = today in week_dates
            enriched_weeks.append(
                {
                    "days": days,
                    "is_current_week": is_current_week,
                }
            )
        context["weeks_enriched"] = enriched_weeks
