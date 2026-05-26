# Management Screens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the three Manager management screens (Agents, Clients, Methodologies) plus their detail/edit views — six surfaces total spanning seven templates, on top of the design foundation and the previously shipped Dashboard / Visits / Visit Detail screens.

**Architecture:** Three phases on top of branch `manager-screens` (which already has `placeholders.py`, `screens.css`, the foundation, and three Manager screens). Phase 1 appends ~280 lines of CSS for `.atable`, `.ctable`, `.method-grid`/`.mcard`, and form-page chrome, plus extends `voice/placeholders.py` with five new helper functions. Phase 2 wires the three list views (Agents, Clients, Methodologies). Phase 3 wires the four single views (a new Agent Detail with its own URL + view, restyled Agent Form, restructured Client Detail, restyled Methodology Form). No model or selector changes; existing form contracts and query params preserved.

**Tech Stack:** Django 4.2 templates, hand-rolled CSS via design tokens shipped in the foundation, existing selectors + form classes.

**Source spec:** [docs/superpowers/specs/2026-05-26-management-screens-design.md](../specs/2026-05-26-management-screens-design.md)

**Builds on:** branch `manager-screens` at commit `6b5d97a` (which is the spec commit on top of the prior implementation).

**Design package source files** (still in `/tmp/claude-design/` from earlier extraction; if absent, re-extract):
- `/tmp/claude-design/sales-assistant-calendar-design-system/project/agents-list-styles.css`
- `/tmp/claude-design/sales-assistant-calendar-design-system/project/clients-directory-styles.css`
- `/tmp/claude-design/sales-assistant-calendar-design-system/project/methodologies-grid-styles.css`

---

## Conventions

- Working directory is the repo root: `/Users/alex/Code/proj-salesassistant`.
- **DO NOT commit per task.** Per the established pattern, work stays uncommitted across all phases; final commit happens in Task 12.
- After every file change, run `python manage.py check` to confirm no template-syntax errors.
- Dev server is on port 8003 (per user memory).

---

## Phase 1 — Shared CSS + placeholder helpers

### Task 1: Append list/grid/form CSS to `static/css/screens.css`

**Files:**
- Modify: `static/css/screens.css` (append)

**Step 1: Append the following CSS block to the END of `static/css/screens.css`**

```css

/* ============================================================================
   Agents list (.atable)
   ============================================================================ */
.atable {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  width: 100%;
  border-collapse: collapse;
  overflow: hidden;
}
.atable thead th {
  height: 48px;
  text-align: left;
  padding: 0 16px;
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
  border-bottom: 1px solid var(--border-hairline);
}
.atable tbody td {
  height: 64px;
  padding: 0 16px;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 14px;
  color: var(--fg-strong);
  border-bottom: 1px solid var(--border-hairline);
  vertical-align: middle;
}
.atable tbody tr:last-child td { border-bottom: none; }
.atable tbody tr:hover { background: var(--zinc-50); }
.atable tbody tr:hover .more { opacity: 1; }
.atable .who { display: flex; align-items: center; gap: 12px; }
.atable .who .stack { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.atable .who .nm {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 14px;
  color: var(--fg-strong);
  line-height: 1;
}
.atable .who .em {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--fg-muted);
  line-height: 1;
}
.atable .loadbar {
  width: 120px;
  height: 8px;
  background: var(--zinc-100);
  border-radius: var(--radius-pill);
  overflow: hidden;
  display: inline-block;
}
.atable .loadbar .fill {
  display: block;
  height: 100%;
  background: var(--cyan-500);
  border-radius: var(--radius-pill);
}
.atable .num {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 14px;
  color: var(--fg-strong);
  font-feature-settings: 'tnum';
}
.atable .num .dim { color: var(--fg-muted); font-weight: 600; }
.atable .more {
  width: 32px; height: 32px;
  border-radius: 50%;
  background: transparent;
  border: none;
  color: var(--fg-muted);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  transition: opacity 120ms ease-out, background-color 120ms ease-out;
}
.atable .more:hover { background: var(--zinc-100); color: var(--fg-strong); }
.atable .more .ic { width: 14px; height: 14px; }

/* ============================================================================
   Clients list (.ctable + .clients-search)
   ============================================================================ */
.clients-search {
  display: flex;
  align-items: center;
  gap: 8px;
  height: 44px;
  padding: 0 16px;
  background: var(--bg-surface);
  border: 1px solid var(--border-default);
  border-radius: var(--radius-pill);
}
.clients-search input {
  border: none;
  background: transparent;
  font: inherit;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 14px;
  color: var(--fg-strong);
  outline: none;
  flex: 1;
}
.clients-search .ic { width: 16px; height: 16px; color: var(--fg-muted); }
.ctable {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  width: 100%;
  border-collapse: collapse;
  overflow: hidden;
}
.ctable thead th {
  height: 48px;
  text-align: left;
  padding: 0 16px;
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
  border-bottom: 1px solid var(--border-hairline);
}
.ctable tbody td {
  height: 64px;
  padding: 0 16px;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 14px;
  color: var(--fg-strong);
  border-bottom: 1px solid var(--border-hairline);
  vertical-align: middle;
}
.ctable tbody tr:last-child td { border-bottom: none; }
.ctable tbody tr:hover { background: var(--zinc-50); }
.ctable tbody tr:hover .more { opacity: 1; }
.ctable .client { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.ctable .client .nm {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 14px;
  color: var(--fg-strong);
  line-height: 1;
}
.ctable .client .dom {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--fg-muted);
  line-height: 1;
}
.ctable .visits-cell .n {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 14px;
  font-feature-settings: 'tnum';
}
.ctable .visits-cell .last {
  display: block;
  font-size: 12px;
  color: var(--fg-muted);
  font-weight: 600;
  margin-top: 2px;
}
.ctable .intel { display: flex; flex-direction: column; gap: 4px; }
.ctable .intel .row {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  font-weight: 600;
}
.ctable .intel .row .dot {
  width: 6px; height: 6px;
  border-radius: 50%;
  background: var(--green-700);
}
.ctable .intel .row.miss .dot { background: var(--zinc-300); }
.ctable .intel .row.miss { color: var(--fg-muted); }
.ctable .synced {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  font-weight: 600;
  color: var(--fg-strong);
}
.ctable .synced .dot {
  width: 8px; height: 8px;
  border-radius: 50%;
}
.ctable .synced.fresh .dot { background: var(--green-700); }
.ctable .synced.stale .dot { background: var(--amber-800); }
.ctable .synced.stale { color: var(--fg-muted); }
.ctable .more {
  width: 32px; height: 32px;
  border-radius: 50%;
  background: transparent;
  border: none;
  color: var(--fg-muted);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  transition: opacity 120ms ease-out, background-color 120ms ease-out;
}
.ctable .more:hover { background: var(--zinc-100); color: var(--fg-strong); }
.ctable .more .ic { width: 14px; height: 14px; }

/* ============================================================================
   Methodologies grid (.method-grid + .mcard)
   ============================================================================ */
.method-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 20px;
}
.mcard {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  padding: 24px;
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.mcard.is-inactive {
  background: var(--zinc-50);
}
.mcard.is-inactive .top h2,
.mcard.is-inactive .desc,
.mcard.is-inactive .mini .v {
  color: var(--fg-muted);
}
.mcard .top {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.mcard .top h2 {
  flex: 1 1 auto;
  margin: 0;
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 18px;
  line-height: 1.1;
  color: var(--fg-strong);
}
.default-badge {
  display: inline-flex;
  align-items: center;
  height: 22px;
  padding: 0 10px;
  background: var(--cyan-100);
  color: var(--cyan-600);
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
}
.mcard .desc {
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
.mcard .stats {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}
.mcard .stats .mini {
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-md);
  padding: 12px;
}
.mcard .stats .mini .l {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
}
.mcard .stats .mini .v {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 24px;
  color: var(--fg-strong);
  margin-top: 4px;
  font-feature-settings: 'tnum';
}
.mcard .indicators {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.mcard .ind-row {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
}
.mcard .ind-row .dot {
  width: 6px; height: 6px;
  border-radius: 50%;
}
.mcard .ind-row.on .dot { background: var(--green-700); }
.mcard .ind-row.on { color: var(--fg-strong); }
.mcard .ind-row.off .dot { background: var(--zinc-300); }
.mcard .ind-row.off { color: var(--fg-muted); }
.mcard .foot {
  margin-top: auto;
  padding-top: 8px;
  border-top: 1px solid var(--border-hairline);
}
.mcard .edit-link {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 13px;
  color: var(--cyan-600);
}
.mcard .edit-link:hover { color: var(--cyan-500); }

/* ============================================================================
   Form-page chrome (.form-layout, .form-card, .form-fieldset, .form-row)
   Used by agent_form and methodology_form. Mirrors .detail-grid rhythm.
   ============================================================================ */
.form-layout {
  display: grid;
  grid-template-columns: 1fr 320px;
  gap: 16px;
}
.form-card {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  padding: 32px;
}
.form-fieldset {
  border: none;
  padding: 0;
  margin: 0 0 32px;
}
.form-fieldset:last-child { margin-bottom: 0; }
.form-fieldset h3 {
  margin: 0 0 16px;
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 14px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--fg-muted);
  padding-bottom: 12px;
  border-bottom: 1px solid var(--border-hairline);
}
.form-row {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-bottom: 20px;
}
.form-row:last-child { margin-bottom: 0; }
.form-row label {
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
  color: var(--fg-strong);
}
.form-row input[type="text"],
.form-row input[type="email"],
.form-row input[type="password"],
.form-row input[type="tel"],
.form-row input[type="url"],
.form-row input[type="number"],
.form-row textarea,
.form-row select {
  height: 40px;
  padding: 0 12px;
  border: 1px solid var(--border-default);
  border-radius: var(--radius-md);
  font-family: var(--font-ui);
  font-weight: 500;
  font-size: 14px;
  color: var(--fg-strong);
  background: var(--bg-surface);
  width: 100%;
}
.form-row textarea {
  min-height: 120px;
  padding: 10px 12px;
  resize: vertical;
  font-family: var(--font-tile);
  font-weight: 600;
}
.form-row input:focus,
.form-row textarea:focus,
.form-row select:focus {
  outline: none;
  border-color: var(--focus-ring);
}
.form-row .helptext {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--fg-muted);
}
.form-row .field-error {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--rose-700);
}
.form-row.checkbox-row {
  flex-direction: row;
  align-items: center;
  gap: 10px;
}
.form-row.checkbox-row input[type="checkbox"] {
  width: 18px;
  height: 18px;
  margin: 0;
}
.form-row.checkbox-row label {
  font-weight: 500;
  font-size: 13px;
  margin: 0;
  cursor: pointer;
}
.form-sidebar {
  display: flex;
  flex-direction: column;
  gap: 16px;
  position: sticky;
  top: 24px;
  align-self: start;
}
.form-actions {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.form-actions .btn-primary,
.form-actions .btn-secondary {
  width: 100%;
  justify-content: center;
}
.form-sidebar .card h3 {
  margin: 0 0 12px;
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 12px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
}
.form-sidebar .checklist {
  list-style: none;
  padding: 0;
  margin: 0;
  counter-reset: step;
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.form-sidebar .checklist li {
  counter-increment: step;
  position: relative;
  padding-left: 28px;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg);
  line-height: 1.4;
}
.form-sidebar .checklist li::before {
  content: counter(step);
  position: absolute;
  left: 0;
  top: -1px;
  width: 20px;
  height: 20px;
  border-radius: 50%;
  background: var(--cyan-100);
  color: var(--cyan-600);
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 11px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.form-sidebar .status-list {
  list-style: none;
  padding: 0;
  margin: 0;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.form-sidebar .status-list li {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
}
.form-sidebar .status-list .dot {
  width: 8px; height: 8px;
  border-radius: 50%;
}
.form-sidebar .status-list .dot.on { background: var(--green-700); }
.form-sidebar .status-list .dot.off { background: var(--zinc-300); }
.form-sidebar .status-list li.off { color: var(--fg-muted); }
```

**Step 2: Verify**

```bash
wc -l static/css/screens.css
python manage.py check
```

Expected: ~1360 lines now (was 1083); check passes.

**Step 3: Confirm previous sections intact**

```bash
grep -c "^\.outcome-chip\|^\.metastrip\|^\.alert-row\|^\.filterbar" static/css/screens.css
```

Expected: at least 4 (one per pattern; all earlier rule blocks should still be present).

DO NOT commit.

---

### Task 2: Append new placeholder helpers to `voice/placeholders.py`

**Files:**
- Modify: `voice/placeholders.py` (append)

**Step 1: Append the following Python code to the END of `voice/placeholders.py`**

```python


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
        # Build an 8-slot load bar from today's visits/calls.
        # Reuses the readiness color tokens: 'cyan' (upcoming), 'zinc' (done), 'empty'.
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
        # Success percentage: real if call_success_rate, else mock from id
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

    # Stat-row placeholders
    agent_count = context.get("agent_count", 0) or 0
    configured_count = context.get("configured_count", 0) or 0
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
    """Mutate the ClientListView context dict in place.

    Requires upstream keys: clients (list of dicts with 'client' key + counts),
    total_count, with_summary."""
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
    """Mutate the MethodologyListView context dict in place.

    Requires upstream keys: methodologies (list of dicts with 'methodology' key
    + counts + flags), total_count, active_count."""
    enriched = []
    pdf_count = 0
    for md in context["methodologies"]:
        m = md["methodology"]
        desc = m.description or ""
        # Truncate to ~120 chars at a word boundary
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

    # Build today's load bars (8-slot)
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

    # KV strip: Email, Phone, Methodology, Pipedrive
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

    # Stat row
    agent_stat_row = [
        {"label": "Visits today", "value": len(today_visits), "tone": "default"},
        {"label": "Completed", "value": len(completed_today), "tone": "green"},
        {"label": "Active now", "value": len(active_now), "tone": "cyan"},
        {"label": "Success rate", "value": f"{55 + (agent.id % 35)}%", "tone": "default"},
    ]

    # Enriched recent visits (last 20)
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

    # Enriched recent calls (last 10)
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

    # Agent status — derived from today's load
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

    # Configuration indicators
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
    """Return a dict of extras to update the ClientDetailView context.

    Input is the dict already returned by get_client_detail (which the view
    spreads into context); we add visual extras on top."""
    client = client_detail.get("client")
    visits = client_detail.get("visits") or []
    agents = client_detail.get("agents") or []
    recent_calls = client_detail.get("recent_calls") or []

    # KV strip: Industry, Domain, CRM ID, Last Synced
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

    # Stat row: Total visits, Completed, Completion %, Active agents
    completion_rate = client_detail.get("completion_rate", 0) or 0
    client_stat_row = [
        {"label": "Total visits", "value": client_detail.get("total_visits", 0), "tone": "default"},
        {"label": "Completed", "value": client_detail.get("completed_visits", 0), "tone": "green"},
        {"label": "Completion", "value": f"{completion_rate}%", "tone": "cyan"},
        {"label": "Active agents", "value": len(agents), "tone": "default"},
    ]

    # Enriched agents (assigned)
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

    # Enriched visit history rows
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

    # Enriched recent calls
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

    # Client intel summary (use real ai_summary if present, else placeholder)
    intel_summary = (
        client.ai_summary
        if client and client.ai_summary
        else "No client intel summary on file yet. AI extraction will populate this when the next sync runs."
    )

    return {
        "client_kv_strip": client_kv_strip,
        "client_stat_row": client_stat_row,
        "agents_enriched": agents_enriched,
        "visits_enriched": visits_enriched,
        "recent_calls_enriched": recent_calls_enriched,
        "client_intel_summary": intel_summary,
        "client_domain_short": domain_str,
        "client_last_synced_ago": _relative_ago(client.last_synced_at) if client else "—",
    }
```

**Step 2: Verify imports + Django**

```bash
python -c "from voice import placeholders; print([n for n in dir(placeholders) if 'extras' in n])"
python manage.py check
```

Expected: list includes `agent_detail_extras`, `agents_extras`, `client_detail_extras`, `clients_extras`, `dashboard_extras`, `methodologies_extras`, `visit_detail_extras`, `visits_extras`. Check passes.

DO NOT commit.

---

## Phase 2 — Three list views

### Task 3: Extend `AgentManagementView` + rewrite `agent_list.html`

**Files:**
- Modify: `voice/views.py` (one-line addition in `AgentManagementView`)
- Modify: `voice/templates/voice/manager/agent_list.html` (full rewrite)

**Step 1: Add helper call to the view**

In `voice/views.py`, locate `AgentManagementView.get`. After the context dict is fully populated, just before `return render(...)`, insert:

```python
        placeholders.agents_extras(context)
```

Match the existing indentation (8 spaces).

**Step 2: Replace the entire `agent_list.html` file**

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}Agents — Sales Assistant{% endblock %}

{% block header_utility %}
<div class="toggle">
    <button type="button" class="on">All</button>
    <button type="button">Active</button>
    <button type="button">Archived</button>
</div>
{% endblock %}

{% block display_title %}Agents{% endblock %}
{% block display_subtitle %}<div class="sub">{{ agent_count }} agents · {{ configured_count }} configured</div>{% endblock %}

{% block header_actions %}
<a href="{% url 'voice:agent_add' %}" class="btn btn-primary"><span class="ic ic-plus ic-14"></span> New agent</a>
{% endblock %}

{% block content %}

{# ─── Stat row ─── #}
<div class="stats">
    {% include "voice/partials/stat_card.html" with label="Total agents" value=agent_count %}
    {% include "voice/partials/stat_card.html" with label="Configured" value=configured_count tone="green" %}
    {% include "voice/partials/stat_card.html" with label="Live now" value=agents_live_now tone="cyan" %}
    {% include "voice/partials/stat_card.html" with label="Avg success" value=agents_avg_success|stringformat:"d"|add:"%" %}
</div>

{# ─── Agents table ─── #}
<table class="tbl atable">
    <thead>
        <tr>
            <th>Agent</th>
            <th>Methodology</th>
            <th>Today's load</th>
            <th style="width: 90px;">Done</th>
            <th style="width: 90px;">Success</th>
            <th style="width: 48px;"></th>
        </tr>
    </thead>
    <tbody>
        {% for ad in agents %}
        <tr>
            <td>
                <div class="who">
                    {% include "voice/partials/avatar.html" with initial=ad.agent.username|first|upper palette=ad.avatar_palette size=36 %}
                    <div class="stack">
                        <span class="nm">{{ ad.agent.get_full_name|default:ad.agent.username }}</span>
                        <span class="em">{{ ad.agent.email|default:"—" }}</span>
                    </div>
                </div>
            </td>
            <td>
                {% if ad.agent.default_methodology %}
                <span class="meth-pill">{{ ad.agent.default_methodology.name }}</span>
                {% else %}<span style="color:var(--fg-muted);">—</span>{% endif %}
            </td>
            <td>
                <span class="loadbar"><span class="fill" style="width: {{ ad.load_pct }}%;"></span></span>
            </td>
            <td><span class="num">{{ ad.visits_complete_today|default:0 }}<span class="dim">/{{ ad.visits_today|default:0 }}</span></span></td>
            <td><span class="num">{{ ad.success_pct }}%</span></td>
            <td><a href="{% url 'voice:agent_detail' agent_id=ad.agent.id %}" class="more" aria-label="View agent"><span class="ic ic-menu-dots"></span></a></td>
        </tr>
        {% empty %}
        <tr><td colspan="6" style="text-align:center;padding:32px;color:var(--fg-muted);">No agents on file.</td></tr>
        {% endfor %}
    </tbody>
</table>

{% endblock %}
```

**Step 3: Verify**

```bash
python manage.py check
```

Expected: passes.

DO NOT commit.

---

### Task 4: Extend `ClientListView` + rewrite `client_list.html`

**Files:**
- Modify: `voice/views.py` (one-line addition in `ClientListView`)
- Modify: `voice/templates/voice/manager/client_list.html` (full rewrite)

**Step 1: Add helper call**

In `voice/views.py`, locate `ClientListView.get`. After the context dict is fully populated, just before `return render(...)`, insert:

```python
        placeholders.clients_extras(context)
```

**Step 2: Replace the entire `client_list.html`**

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}Clients — Sales Assistant{% endblock %}

{% block display_title %}Clients{% endblock %}
{% block display_subtitle %}<div class="sub">{{ total_count }} clients · {{ with_summary }} with AI summary</div>{% endblock %}

{% block header_actions %}
<a href="{% url 'voice:client_create' %}" class="btn btn-primary"><span class="ic ic-plus ic-14"></span> New client</a>
{% endblock %}

{% block content %}

{# ─── Stat row ─── #}
<div class="stats">
    {% include "voice/partials/stat_card.html" with label="Total" value=total_count %}
    {% include "voice/partials/stat_card.html" with label="With AI summary" value=with_summary tone="green" %}
    {% include "voice/partials/stat_card.html" with label="With CRM" value=clients_with_crm_count tone="cyan" %}
    {% include "voice/partials/stat_card.html" with label="Stale" value=clients_stale_count tone="rose" %}
</div>

{# ─── Search bar ─── #}
<form method="get" class="clients-search">
    <span class="ic ic-search ic-16"></span>
    <input type="search" name="q" value="{{ search|default:'' }}" placeholder="Search by name, domain, industry…">
</form>

{# ─── Clients table ─── #}
<table class="tbl ctable">
    <thead>
        <tr>
            <th>Client</th>
            <th>Industry</th>
            <th>Visits</th>
            <th style="width: 80px;">Agents</th>
            <th style="width: 110px;">Intel</th>
            <th style="width: 130px;">Last synced</th>
            <th style="width: 48px;"></th>
        </tr>
    </thead>
    <tbody>
        {% for cd in clients %}
        <tr>
            <td>
                <div class="client">
                    <span class="nm">{{ cd.client.name }}</span>
                    <span class="dom">{{ cd.domain_short|default:"—" }}</span>
                </div>
            </td>
            <td>{{ cd.client.industry|default:"—" }}</td>
            <td class="visits-cell">
                <span class="n">{{ cd.total_visits }}</span>
                <span class="last">last {{ cd.last_visit_str }}</span>
            </td>
            <td><span class="num">{{ cd.agent_count }}</span></td>
            <td>
                <div class="intel">
                    <span class="row{% if not cd.intel_ai_on %} miss{% endif %}"><span class="dot"></span>AI summary</span>
                    <span class="row{% if not cd.intel_crm_on %} miss{% endif %}"><span class="dot"></span>CRM linked</span>
                </div>
            </td>
            <td>
                <span class="synced {% if cd.synced_fresh %}fresh{% else %}stale{% endif %}">
                    <span class="dot"></span>{{ cd.synced_ago }}
                </span>
            </td>
            <td><a href="{% url 'voice:client_detail' client_id=cd.client.id %}" class="more" aria-label="View client"><span class="ic ic-menu-dots"></span></a></td>
        </tr>
        {% empty %}
        <tr><td colspan="7" style="text-align:center;padding:32px;color:var(--fg-muted);">No clients found.</td></tr>
        {% endfor %}
    </tbody>
</table>

{% endblock %}
```

**Step 3: Verify**

```bash
python manage.py check
```

Expected: passes.

DO NOT commit.

---

### Task 5: Extend `MethodologyListView` + rewrite `methodology_list.html`

**Files:**
- Modify: `voice/views.py` (one-line addition in `MethodologyListView`)
- Modify: `voice/templates/voice/manager/methodology_list.html` (full rewrite)

**Step 1: Add helper call**

In `voice/views.py`, locate `MethodologyListView.get`. After the context dict is fully populated, just before `return render(...)`, insert:

```python
        placeholders.methodologies_extras(context)
```

**Step 2: Replace the entire `methodology_list.html`**

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}Methodologies — Sales Assistant{% endblock %}

{% block header_utility %}
<div class="toggle">
    <button type="button" class="on">All</button>
    <button type="button">Active</button>
    <button type="button">Archived</button>
</div>
{% endblock %}

{% block display_title %}Methodologies{% endblock %}
{% block display_subtitle %}<div class="sub">{{ total_count }} methodologies · {{ active_count }} active</div>{% endblock %}

{% block header_actions %}
<a href="{% url 'voice:methodology_create' %}" class="btn btn-primary"><span class="ic ic-plus ic-14"></span> New methodology</a>
{% endblock %}

{% block content %}

{# ─── Stat row ─── #}
<div class="stats">
    {% include "voice/partials/stat_card.html" with label="Total" value=total_count %}
    {% include "voice/partials/stat_card.html" with label="Active" value=active_count tone="green" %}
    {% include "voice/partials/stat_card.html" with label="With PDF" value=methodologies_with_pdf_count tone="cyan" %}
</div>

{# ─── Methodologies grid ─── #}
<div class="method-grid">
    {% for md in methodologies %}
    <div class="mcard {% if not md.methodology.is_active %}is-inactive{% endif %}">
        <div class="top">
            <h2>{{ md.methodology.name }}</h2>
            {% if md.is_system_default %}<span class="default-badge">Default</span>{% endif %}
            {% include "voice/partials/status_pill.html" with variant=md.status_tone label=md.status_label %}
        </div>
        <div class="desc">{{ md.desc_short|default:"No description." }}</div>
        <div class="stats">
            <div class="mini"><div class="l">Agents</div><div class="v">{{ md.agents_using }}</div></div>
            <div class="mini"><div class="l">Visits</div><div class="v">{{ md.visits_using }}</div></div>
        </div>
        <div class="indicators">
            <span class="ind-row {% if md.has_pdf %}on{% else %}off{% endif %}"><span class="dot"></span>{% if md.has_pdf %}PDF attached{% else %}No PDF{% endif %}</span>
            <span class="ind-row {% if md.has_summary %}on{% else %}off{% endif %}"><span class="dot"></span>{% if md.has_summary %}AI summary ready{% else %}No AI summary{% endif %}</span>
        </div>
        <div class="foot">
            <a href="{% url 'voice:methodology_edit' methodology_id=md.methodology.id %}" class="edit-link">Edit methodology →</a>
        </div>
    </div>
    {% empty %}
    <div style="grid-column: 1 / -1;text-align:center;padding:32px;color:var(--fg-muted);">No methodologies on file.</div>
    {% endfor %}
</div>

{% endblock %}
```

**Step 3: Verify**

```bash
python manage.py check
```

Expected: passes.

DO NOT commit.

---

## Phase 3 — Four single views

### Task 6: Add `AgentDetailView` + new URL + create `agent_detail.html`

**Files:**
- Modify: `voice/urls.py` (add 1 URL pattern)
- Modify: `voice/views.py` (add new view class)
- Modify: `voice/templates/voice/base.html` (extend Agents row active-state check)
- Create: `voice/templates/voice/manager/agent_detail.html`

**Step 1: Add the URL pattern**

In `voice/urls.py`, find the existing line for `agent_management`:

```python
path('manager/agents/', views.AgentManagementView.as_view(), name='agent_management'),
```

Insert this line immediately after it:

```python
path('manager/agents/<int:agent_id>/', views.AgentDetailView.as_view(), name='agent_detail'),
```

**Step 2: Add the view class to `voice/views.py`**

Locate `AgentManagementView`. Right AFTER its class definition (after the closing of its methods), insert this new class:

```python
class AgentDetailView(SuperuserRequiredMixin, View):
    """Read-only detail view for a single sales agent, with recent visits + calls."""

    def get(self, request, agent_id):
        from django.shortcuts import get_object_or_404
        agent = get_object_or_404(User, id=agent_id, is_sales_agent=True)
        recent_visits = list(get_agent_visits(agent)[:20])
        recent_calls = list(
            CallAttempt.objects.filter(visit__agent=agent)
            .select_related('visit', 'visit__client')
            .order_by('-created_at')[:10]
        )
        context = {
            'agent': agent,
            'recent_visits': recent_visits,
            'recent_calls': recent_calls,
        }
        context.update(placeholders.agent_detail_extras(agent, recent_visits, recent_calls))
        return render(request, 'voice/manager/agent_detail.html', context)
```

Check the imports at the top of `voice/views.py` and make sure `get_agent_visits` is imported. If it's not, add it to the existing `from .selectors import (...)` block.

**Step 3: Extend the Agents sidebar active-state check in `base.html`**

In `voice/templates/voice/base.html`, find the Agents nav row:

```django
<a href="{% url 'voice:agent_management' %}" class="row {% if request.resolver_match.url_name == 'agent_management' or request.resolver_match.url_name == 'agent_add' or request.resolver_match.url_name == 'agent_methodology' %}active{% endif %}">
```

Add `agent_detail` to the OR chain:

```django
<a href="{% url 'voice:agent_management' %}" class="row {% if request.resolver_match.url_name == 'agent_management' or request.resolver_match.url_name == 'agent_add' or request.resolver_match.url_name == 'agent_methodology' or request.resolver_match.url_name == 'agent_detail' %}active{% endif %}">
```

**Step 4: Create `voice/templates/voice/manager/agent_detail.html`**

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}{{ agent.get_full_name|default:agent.username }} — Sales Assistant{% endblock %}

{% block header_utility %}
<nav class="breadcrumb">
    <a href="{% url 'voice:agent_management' %}">Agents</a>
    <span class="sep">/</span>
    <span class="cur">{{ agent.get_full_name|default:agent.username }}</span>
</nav>
{% endblock %}

{% block display_title %}{{ agent.get_full_name|default:agent.username }}{% endblock %}

{% block display_subtitle %}
<div class="metastrip">
    <span>{{ agent.email|default:"no email" }}</span>
    <span>·</span>
    <span>{{ agent.phone_number|default:"no phone" }}</span>
    <span>·</span>
    <span class="meth">{{ agent.default_methodology.name|default:"No methodology" }}</span>
    <span>·</span>
    <span class="vid">{{ agent_id_code }}</span>
</div>
{% endblock %}

{% block header_actions %}
{% include "voice/partials/status_pill.html" with variant=agent_status_variant label=agent_status_label %}
<a href="#" class="btn btn-secondary">Edit</a>
<button type="button" class="icon-btn" aria-label="More"><span class="ic ic-menu-dots ic-16"></span></button>
{% endblock %}

{% block content %}

{# ─── Stat row ─── #}
<div class="stats">
    {% for s in agent_stat_row %}
    {% include "voice/partials/stat_card.html" with label=s.label value=s.value tone=s.tone %}
    {% endfor %}
</div>

{# ─── 70/30 detail grid ─── #}
<div class="detail-grid">
    <div class="detail-col">

        {# Meta card #}
        <div class="dcard">
            <div class="kv-strip">
                {% for kv in agent_kv_strip %}
                <div class="kv">
                    <div class="label">{{ kv.label }}</div>
                    <div class="value">{{ kv.value }}</div>
                </div>
                {% endfor %}
            </div>
        </div>

        {# Today's load #}
        <div class="dcard">
            <h3>Today's load</h3>
            <div class="agent">
                <div class="bars">
                    {% for color in today_load_bars %}<span class="b-{{ color }}"></span>{% endfor %}
                </div>
                <div class="footer">
                    <span class="lbl">Slots</span>
                    <span class="success">{{ recent_visits|length }} recent visits</span>
                </div>
            </div>
        </div>

        {# Recent Visits #}
        <div class="dcard">
            <h3>Recent visits</h3>
            <table class="tbl">
                <thead>
                    <tr>
                        <th>Date</th>
                        <th>Client</th>
                        <th>Methodology</th>
                        <th>Status</th>
                    </tr>
                </thead>
                <tbody>
                    {% for v in recent_visits_enriched %}
                    <tr>
                        <td>{{ v.visit.start_time|date:"M j H:i" }}</td>
                        <td>{{ v.client_name }}<span class="meta">{{ v.client_industry }}</span></td>
                        <td><span class="meth-pill">{{ v.visit.methodology.name|default:"—" }}</span></td>
                        <td>
                            {% if v.status == "PLANNED" %}{% include "voice/partials/status_pill.html" with variant="cream" label="Planned" %}
                            {% elif v.status == "PRE_CALL_DONE" %}{% include "voice/partials/status_pill.html" with variant="cyan" label="Pre-Call" %}
                            {% elif v.status == "IN_PROGRESS" %}{% include "voice/partials/status_pill.html" with variant="cyan-filled" label="Active" %}
                            {% elif v.status == "POST_CALL_DONE" %}{% include "voice/partials/status_pill.html" with variant="cream" label="Debrief" %}
                            {% elif v.status == "COMPLETE" %}{% include "voice/partials/status_pill.html" with variant="green" label="Complete" %}{% endif %}
                        </td>
                    </tr>
                    {% empty %}
                    <tr><td colspan="4" style="text-align:center;padding:24px;color:var(--fg-muted);">No recent visits.</td></tr>
                    {% endfor %}
                </tbody>
            </table>
        </div>
    </div>

    <div class="detail-side">

        {# Configuration #}
        <div class="dcard">
            <h3>Configuration</h3>
            <ul class="status-list">
                {% for ind in config_indicators %}
                <li class="{% if not ind.on %}off{% endif %}"><span class="dot {% if ind.on %}on{% else %}off{% endif %}"></span>{{ ind.label }}</li>
                {% endfor %}
            </ul>
        </div>

        {# Recent Calls #}
        <div class="dcard">
            <h3>Recent calls</h3>
            <div style="display:flex;flex-direction:column;gap:12px;">
                {% for c in recent_calls_enriched %}
                <div style="display:flex;align-items:center;gap:10px;font-size:13px;">
                    {% if c.phase == "PRE" %}{% include "voice/partials/call_phase_icon.html" with phase="pre" state="done" %}{% else %}{% include "voice/partials/call_phase_icon.html" with phase="post" state="done" %}{% endif %}
                    <span style="flex:1;font-weight:700;">{{ c.visit.client.name|default:"—" }}</span>
                    <span style="font-size:11px;color:var(--fg-muted);">{{ c.ago }}</span>
                </div>
                {% empty %}
                <p style="margin:0;color:var(--fg-muted);font-size:13px;">No recent calls.</p>
                {% endfor %}
            </div>
        </div>

        {# Methodology #}
        {% if agent.default_methodology %}
        <div class="dcard">
            <h3>Methodology</h3>
            <p style="font-family:var(--font-ui);font-weight:800;font-size:14px;margin:0 0 8px;">{{ agent.default_methodology.name }}</p>
            <a href="{% url 'voice:methodology_edit' methodology_id=agent.default_methodology.id %}" class="edit-link" style="color:var(--cyan-600);font-weight:700;font-size:13px;">View methodology →</a>
        </div>
        {% endif %}
    </div>
</div>

{% endblock %}
```

**Step 5: Verify**

```bash
python manage.py check
```

Expected: `System check identified no issues (0 silenced).`

DO NOT commit.

---

### Task 7: Rewrite `agent_form.html`

**Files:**
- Modify: `voice/templates/voice/manager/agent_form.html` (full rewrite)

**Step 1: Read the existing template to learn the form field names**

```bash
cat voice/templates/voice/manager/agent_form.html | head -100
```

The current form fields are: `username`, `first_name`, `last_name`, `email`, `password1`, `password2`, `phone_number`, `pipedrive_user_id`. POST target is `{% url 'voice:agent_add' %}`.

**Step 2: Replace the entire file**

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}New agent — Sales Assistant{% endblock %}

{% block header_utility %}
<nav class="breadcrumb">
    <a href="{% url 'voice:agent_management' %}">Agents</a>
    <span class="sep">/</span>
    <span class="cur">New agent</span>
</nav>
{% endblock %}

{% block display_title %}New agent{% endblock %}

{% block content %}

{% if form.non_field_errors %}
<div class="toast toast-error" style="margin-bottom:16px;">
    {% for error in form.non_field_errors %}<span>{{ error }}</span>{% endfor %}
</div>
{% endif %}

<form method="post" class="form-layout">
    {% csrf_token %}
    <div class="form-card">

        <fieldset class="form-fieldset">
            <h3>Account</h3>
            <div class="form-row">
                <label for="{{ form.username.id_for_label }}">Username</label>
                <input type="text" name="{{ form.username.name }}" id="{{ form.username.id_for_label }}" value="{{ form.username.value|default:'' }}" required>
                {% if form.username.help_text %}<span class="helptext">{{ form.username.help_text }}</span>{% endif %}
                {% if form.username.errors %}<span class="field-error">{{ form.username.errors.0 }}</span>{% endif %}
            </div>
            <div class="form-row">
                <label for="{{ form.first_name.id_for_label }}">First name</label>
                <input type="text" name="{{ form.first_name.name }}" id="{{ form.first_name.id_for_label }}" value="{{ form.first_name.value|default:'' }}">
                {% if form.first_name.errors %}<span class="field-error">{{ form.first_name.errors.0 }}</span>{% endif %}
            </div>
            <div class="form-row">
                <label for="{{ form.last_name.id_for_label }}">Last name</label>
                <input type="text" name="{{ form.last_name.name }}" id="{{ form.last_name.id_for_label }}" value="{{ form.last_name.value|default:'' }}">
                {% if form.last_name.errors %}<span class="field-error">{{ form.last_name.errors.0 }}</span>{% endif %}
            </div>
            <div class="form-row">
                <label for="{{ form.email.id_for_label }}">Email</label>
                <input type="email" name="{{ form.email.name }}" id="{{ form.email.id_for_label }}" value="{{ form.email.value|default:'' }}" required>
                {% if form.email.errors %}<span class="field-error">{{ form.email.errors.0 }}</span>{% endif %}
            </div>
        </fieldset>

        <fieldset class="form-fieldset">
            <h3>Password</h3>
            <div class="form-row">
                <label for="{{ form.password1.id_for_label }}">Password</label>
                <input type="password" name="{{ form.password1.name }}" id="{{ form.password1.id_for_label }}" required autocomplete="new-password">
                {% if form.password1.help_text %}<span class="helptext">{{ form.password1.help_text|striptags }}</span>{% endif %}
                {% if form.password1.errors %}<span class="field-error">{{ form.password1.errors.0 }}</span>{% endif %}
            </div>
            <div class="form-row">
                <label for="{{ form.password2.id_for_label }}">Confirm password</label>
                <input type="password" name="{{ form.password2.name }}" id="{{ form.password2.id_for_label }}" required autocomplete="new-password">
                {% if form.password2.errors %}<span class="field-error">{{ form.password2.errors.0 }}</span>{% endif %}
            </div>
        </fieldset>

        <fieldset class="form-fieldset">
            <h3>Configuration</h3>
            <div class="form-row">
                <label for="{{ form.phone_number.id_for_label }}">Phone number</label>
                <input type="tel" name="{{ form.phone_number.name }}" id="{{ form.phone_number.id_for_label }}" value="{{ form.phone_number.value|default:'' }}" placeholder="+1234567890">
                <span class="helptext">Used to place pre/post-call AI conversations. International format with +.</span>
                {% if form.phone_number.errors %}<span class="field-error">{{ form.phone_number.errors.0 }}</span>{% endif %}
            </div>
            <div class="form-row">
                <label for="{{ form.pipedrive_user_id.id_for_label }}">Pipedrive user ID</label>
                <input type="number" name="{{ form.pipedrive_user_id.name }}" id="{{ form.pipedrive_user_id.id_for_label }}" value="{{ form.pipedrive_user_id.value|default:'' }}">
                <span class="helptext">Maps this agent to a Pipedrive user. Leave blank if not using Pipedrive.</span>
                {% if form.pipedrive_user_id.errors %}<span class="field-error">{{ form.pipedrive_user_id.errors.0 }}</span>{% endif %}
            </div>
        </fieldset>

    </div>

    <aside class="form-sidebar">
        <div class="card">
            <div class="form-actions">
                <button type="submit" class="btn btn-primary">Create agent</button>
                <a href="{% url 'voice:agent_management' %}" class="btn btn-secondary">Cancel</a>
            </div>
        </div>
        <div class="card">
            <h3>What happens next</h3>
            <ol class="checklist">
                <li>Account is created and marked as a sales agent.</li>
                <li>Assign a methodology from the agent list.</li>
                <li>Confirm the phone number is reachable for AI calls.</li>
                <li>Verify the Pipedrive user ID matches if syncing.</li>
            </ol>
        </div>
    </aside>
</form>

{% endblock %}
```

**Step 3: Verify**

```bash
python manage.py check
```

Expected: passes.

DO NOT commit.

---

### Task 8: Extend `ClientDetailView` + restructure `client_detail.html`

**Files:**
- Modify: `voice/views.py` (extend `ClientDetailView`)
- Modify: `voice/templates/voice/manager/client_detail.html` (full restructure)

**Step 1: Add helper call in the view**

In `voice/views.py`, locate `ClientDetailView.get`. The current implementation builds context by calling `get_client_detail(client_id)`. After that call, before `return render(...)`, add:

```python
        context.update(placeholders.client_detail_extras(context))
```

(`context` already holds the dict returned by `get_client_detail`, plus any extra keys the view sets. Passing it to the helper lets the helper read what it needs.)

**Step 2: Replace the entire `client_detail.html`**

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}{{ client.name }} — Sales Assistant{% endblock %}

{% block header_utility %}
<nav class="breadcrumb">
    <a href="{% url 'voice:client_list' %}">Clients</a>
    <span class="sep">/</span>
    <span class="cur">{{ client.name }}</span>
</nav>
{% endblock %}

{% block display_title %}{{ client.name }}{% endblock %}

{% block display_subtitle %}
<div class="metastrip">
    <span>{{ client.industry|default:"No industry" }}</span>
    <span>·</span>
    <span>{{ client_domain_short|default:"No domain" }}</span>
    <span>·</span>
    <span class="vid">CRM {{ client.crm_id|default:"—" }}</span>
    <span>·</span>
    <span>Synced {{ client_last_synced_ago }}</span>
</div>
{% endblock %}

{% block header_actions %}
<a href="{% url 'voice:client_edit' client_id=client.id %}" class="btn btn-secondary">Edit</a>
<button type="button" class="icon-btn" aria-label="More"><span class="ic ic-menu-dots ic-16"></span></button>
{% endblock %}

{% block content %}

{# ─── Stat row ─── #}
<div class="stats">
    {% for s in client_stat_row %}
    {% include "voice/partials/stat_card.html" with label=s.label value=s.value tone=s.tone %}
    {% endfor %}
</div>

{# ─── 70/30 detail grid ─── #}
<div class="detail-grid">
    <div class="detail-col">

        {# Meta card #}
        <div class="dcard">
            <div class="kv-strip">
                {% for kv in client_kv_strip %}
                <div class="kv">
                    <div class="label">{{ kv.label }}</div>
                    <div class="value">{{ kv.value }}</div>
                    {% if kv.sub %}<div class="sub">{{ kv.sub }}</div>{% endif %}
                </div>
                {% endfor %}
            </div>
        </div>

        {# Visit History #}
        <div class="dcard">
            <h3>Visit history</h3>
            <table class="tbl">
                <thead>
                    <tr>
                        <th>Date</th>
                        <th>Agent</th>
                        <th>Methodology</th>
                        <th>Status</th>
                    </tr>
                </thead>
                <tbody>
                    {% for v in visits_enriched %}
                    <tr>
                        <td>{{ v.visit.start_time|date:"M j H:i" }}</td>
                        <td>
                            <div style="display:flex;align-items:center;gap:8px;">
                                {% include "voice/partials/avatar.html" with initial=v.visit.agent.username|first|upper palette=v.avatar_palette size=24 %}
                                <span>{{ v.agent_name }}</span>
                            </div>
                        </td>
                        <td><span class="meth-pill">{{ v.methodology_name }}</span></td>
                        <td>
                            {% if v.visit.status == "PLANNED" %}{% include "voice/partials/status_pill.html" with variant="cream" label="Planned" %}
                            {% elif v.visit.status == "PRE_CALL_DONE" %}{% include "voice/partials/status_pill.html" with variant="cyan" label="Pre-Call" %}
                            {% elif v.visit.status == "IN_PROGRESS" %}{% include "voice/partials/status_pill.html" with variant="cyan-filled" label="Active" %}
                            {% elif v.visit.status == "POST_CALL_DONE" %}{% include "voice/partials/status_pill.html" with variant="cream" label="Debrief" %}
                            {% elif v.visit.status == "COMPLETE" %}{% include "voice/partials/status_pill.html" with variant="green" label="Complete" %}{% endif %}
                        </td>
                    </tr>
                    {% empty %}
                    <tr><td colspan="4" style="text-align:center;padding:24px;color:var(--fg-muted);">No visits yet.</td></tr>
                    {% endfor %}
                </tbody>
            </table>
        </div>

        {# Recent Calls #}
        <div class="dcard">
            <h3>Recent calls</h3>
            <div style="display:flex;flex-direction:column;gap:12px;">
                {% for c in recent_calls_enriched %}
                <div style="display:flex;align-items:center;gap:10px;font-size:13px;">
                    {% include "voice/partials/avatar.html" with initial=c.visit.agent.username|first|upper palette=c.agent_palette size=24 %}
                    <span style="font-weight:700;">{{ c.agent_name }}</span>
                    <span style="color:var(--fg-muted);">{{ c.phase|title }} call</span>
                    <span style="flex:1;"></span>
                    <span style="font-size:11px;color:var(--fg-muted);">{{ c.ago }}</span>
                </div>
                {% empty %}
                <p style="margin:0;color:var(--fg-muted);font-size:13px;">No recent calls.</p>
                {% endfor %}
            </div>
        </div>
    </div>

    <div class="detail-side">

        {# AI Summary #}
        <div class="dcard">
            <h3>AI Summary</h3>
            <p class="intel-summary">{{ client_intel_summary|linebreaksbr }}</p>
        </div>

        {# Contacts #}
        <div class="dcard">
            <h3>Contacts</h3>
            {% if client.contacts %}
            <div style="display:flex;flex-direction:column;gap:12px;">
                {% for contact in client.contacts %}
                <div style="display:flex;flex-direction:column;gap:2px;font-size:13px;">
                    <span style="font-weight:800;">{{ contact.name|default:contact.email|default:"Contact" }}</span>
                    {% if contact.role or contact.title %}<span style="color:var(--fg-muted);font-size:12px;">{{ contact.role|default:contact.title }}</span>{% endif %}
                    {% if contact.email %}<span style="color:var(--fg-muted);font-size:12px;">{{ contact.email }}</span>{% endif %}
                    {% if contact.phone %}<span style="color:var(--fg-muted);font-size:12px;">{{ contact.phone }}</span>{% endif %}
                </div>
                {% endfor %}
            </div>
            {% else %}
            <p style="margin:0;color:var(--fg-muted);font-size:13px;">No contacts on file.</p>
            {% endif %}
        </div>

        {# Assigned Agents #}
        <div class="dcard">
            <h3>Assigned agents</h3>
            <div style="display:flex;flex-direction:column;gap:10px;">
                {% for a in agents_enriched %}
                <div style="display:flex;align-items:center;gap:10px;">
                    {% include "voice/partials/avatar.html" with initial=a.agent.username|first|upper palette=a.avatar_palette size=28 %}
                    <div style="flex:1;min-width:0;">
                        <div style="font-weight:800;font-size:13px;">{{ a.agent.get_full_name|default:a.agent.username }}</div>
                        <div style="font-size:11px;color:var(--fg-muted);">{{ a.methodology_name }}</div>
                    </div>
                </div>
                {% empty %}
                <p style="margin:0;color:var(--fg-muted);font-size:13px;">No agents assigned.</p>
                {% endfor %}
            </div>
        </div>

        {# CRM Data #}
        <div class="dcard">
            <h3>CRM data</h3>
            <ul class="status-list">
                <li class="{% if not client.crm_id %}off{% endif %}"><span class="dot {% if client.crm_id %}on{% else %}off{% endif %}"></span>CRM ID: {{ client.crm_id|default:"—" }}</li>
                <li><span class="dot on"></span>{{ client.deal_history|length }} deals</li>
                <li><span class="dot on"></span>{{ client.interaction_history|length }} interactions</li>
            </ul>
        </div>
    </div>
</div>

{% endblock %}
```

**Step 3: Verify**

```bash
python manage.py check
```

Expected: passes.

DO NOT commit.

---

### Task 9: Rewrite `methodology_form.html`

**Files:**
- Modify: `voice/templates/voice/manager/methodology_form.html` (full rewrite)

**Step 1: Replace the entire file**

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}{% if editing %}Edit {{ methodology.name }}{% else %}New methodology{% endif %} — Sales Assistant{% endblock %}

{% block header_utility %}
<nav class="breadcrumb">
    <a href="{% url 'voice:methodology_list' %}">Methodologies</a>
    <span class="sep">/</span>
    <span class="cur">{% if editing %}{{ methodology.name }}{% else %}New methodology{% endif %}</span>
</nav>
{% endblock %}

{% block display_title %}{% if editing %}Edit methodology{% else %}New methodology{% endif %}{% endblock %}

{% block content %}

{% if form.non_field_errors %}
<div class="toast toast-error" style="margin-bottom:16px;">
    {% for error in form.non_field_errors %}<span>{{ error }}</span>{% endfor %}
</div>
{% endif %}

<form method="post" enctype="multipart/form-data" class="form-layout">
    {% csrf_token %}
    <div class="form-card">

        <fieldset class="form-fieldset">
            <h3>Basic information</h3>
            <div class="form-row">
                <label for="{{ form.name.id_for_label }}">Name</label>
                <input type="text" name="{{ form.name.name }}" id="{{ form.name.id_for_label }}" value="{{ form.name.value|default:'' }}" required>
                {% if form.name.errors %}<span class="field-error">{{ form.name.errors.0 }}</span>{% endif %}
            </div>
            <div class="form-row">
                <label for="{{ form.description.id_for_label }}">Description</label>
                <textarea name="{{ form.description.name }}" id="{{ form.description.id_for_label }}">{{ form.description.value|default:'' }}</textarea>
                <span class="helptext">A short summary shown on the methodologies grid.</span>
                {% if form.description.errors %}<span class="field-error">{{ form.description.errors.0 }}</span>{% endif %}
            </div>
            <div class="form-row checkbox-row">
                <input type="checkbox" name="{{ form.is_active.name }}" id="{{ form.is_active.id_for_label }}" {% if form.is_active.value %}checked{% endif %}>
                <label for="{{ form.is_active.id_for_label }}">Active (visible to agents)</label>
            </div>
        </fieldset>

        <fieldset class="form-fieldset">
            <h3>Source material</h3>
            <div class="form-row">
                <label for="{{ form.source_material.id_for_label }}">PDF upload</label>
                {% if editing and methodology.source_material %}
                <span class="helptext">Currently attached: {{ methodology.source_material.name|cut:"methodologies/" }}</span>
                {% endif %}
                <input type="file" name="{{ form.source_material.name }}" id="{{ form.source_material.id_for_label }}" accept="application/pdf">
                <span class="helptext">Upload the methodology PDF. The AI summary regenerates after upload.</span>
                {% if form.source_material.errors %}<span class="field-error">{{ form.source_material.errors.0 }}</span>{% endif %}
            </div>
        </fieldset>

        <fieldset class="form-fieldset">
            <h3>AI summary</h3>
            <div class="form-row">
                <label for="{{ form.ai_summary.id_for_label }}">Summary</label>
                <textarea name="{{ form.ai_summary.name }}" id="{{ form.ai_summary.id_for_label }}" style="min-height:200px;">{{ form.ai_summary.value|default:'' }}</textarea>
                <span class="helptext">Editable. Auto-generated when a PDF is uploaded.</span>
                {% if form.ai_summary.errors %}<span class="field-error">{{ form.ai_summary.errors.0 }}</span>{% endif %}
            </div>
        </fieldset>

    </div>

    <aside class="form-sidebar">
        <div class="card">
            <div class="form-actions">
                <button type="submit" class="btn btn-primary">{% if editing %}Save changes{% else %}Create methodology{% endif %}</button>
                <a href="{% url 'voice:methodology_list' %}" class="btn btn-secondary">Cancel</a>
            </div>
        </div>
        {% if editing %}
        <div class="card">
            <h3>Status</h3>
            <ul class="status-list">
                <li class="{% if not methodology.source_material %}off{% endif %}"><span class="dot {% if methodology.source_material %}on{% else %}off{% endif %}"></span>{% if methodology.source_material %}PDF attached{% else %}No PDF{% endif %}</li>
                <li class="{% if not methodology.ai_summary %}off{% endif %}"><span class="dot {% if methodology.ai_summary %}on{% else %}off{% endif %}"></span>{% if methodology.ai_summary %}AI summary ready{% else %}AI summary pending{% endif %}</li>
                <li class="{% if not methodology.is_active %}off{% endif %}"><span class="dot {% if methodology.is_active %}on{% else %}off{% endif %}"></span>{% if methodology.is_active %}Active{% else %}Inactive{% endif %}</li>
            </ul>
        </div>
        {% endif %}
    </aside>
</form>

{% endblock %}
```

**Step 2: Verify**

```bash
python manage.py check
```

Expected: passes.

DO NOT commit.

---

## Phase 4 — Verification + commit

### Task 10: Cross-cutting smoke verification

**Files:** none.

- [ ] **Step 1: Start dev server (if not already running)**

```bash
python manage.py runserver 0.0.0.0:8003
```

- [ ] **Step 2: Verify Django check + static assets**

```bash
python manage.py check
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8003/static/css/screens.css
```

Expected: check passes; curl returns 200.

- [ ] **Step 3: Smoke-test all 6 screens (browser, logged in as superuser)**

| URL | Expected |
|---|---|
| `/manager/agents/` | `.atable` rows with avatars + load bars + success %, sidebar Agents row active |
| `/manager/agents/<id>/` (any existing agent) | Detail page: meta card, today's load, recent visits table, right rail with Configuration/Recent Calls/Methodology cards |
| `/manager/agents/add/` | Restyled form with 3 fieldsets + sidebar with Save + "What happens next" checklist |
| `/manager/clients/` | `.clients-search` + `.ctable` rows with AI/CRM dots + freshness indicator |
| `/manager/clients/<id>/` (any existing client) | Restructured detail: 70/30 grid with meta/visits/calls on left, AI summary/contacts/agents/CRM on right |
| `/manager/methodologies/` | 2-column `.method-grid` with `.mcard` per methodology, default badge on system default |
| `/manager/methodologies/<id>/edit/` and `/manager/methodologies/add/` | Restyled form with 3 fieldsets + Status sidebar when editing |

- [ ] **Step 4: Exercise form POSTs**

- Submit the agent create form with missing fields — confirm `.field-error` displays under offenders.
- Submit a valid agent create — confirm redirect to agent list and new agent appears.
- Edit an existing methodology, change the name, save — confirm redirect back to list and name persists.

- [ ] **Step 5: Stop the dev server**

Ctrl+C.

No commit yet — Task 11 handles that.

---

### Task 11: Branch + commit

**Files:** none staged yet.

- [ ] **Step 1: Inspect what changed**

```bash
git status --short | head -20
```

- [ ] **Step 2: Create the branch**

```bash
git rev-parse --abbrev-ref HEAD
```

If currently on `manager-screens`, branch off:

```bash
git checkout -b management-screens
```

Working tree carries to the new branch.

- [ ] **Step 3: Stage only this pass's files**

```bash
git add static/css/screens.css \
        voice/placeholders.py \
        voice/views.py \
        voice/urls.py \
        voice/templates/voice/base.html \
        voice/templates/voice/manager/agent_list.html \
        voice/templates/voice/manager/agent_form.html \
        voice/templates/voice/manager/agent_detail.html \
        voice/templates/voice/manager/client_list.html \
        voice/templates/voice/manager/client_detail.html \
        voice/templates/voice/manager/methodology_list.html \
        voice/templates/voice/manager/methodology_form.html \
        docs/superpowers/plans/2026-05-26-management-screens.md
```

Verify with `git status --short`. Other M files should remain unstaged.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
Management screens: Agents, Clients, Methodologies + 4 singles

Implements docs/superpowers/plans/2026-05-26-management-screens.md.

Phase 1 ships shared CSS (.atable, .ctable, .method-grid + .mcard,
form-layout/form-card/form-fieldset/form-row chrome) plus five new
placeholder helpers (agents_extras, clients_extras, methodologies_extras,
agent_detail_extras, client_detail_extras).

Phase 2 wires the three list views: agent_list rebuilt around .atable,
client_list rebuilt around .ctable with a top search input, methodology_list
rebuilt around .method-grid + .mcard.

Phase 3 wires the four single views: a new AgentDetailView (URL + view
+ template) with breadcrumb + metastrip + stepper-like layout, restyled
agent_form using .form-layout, restructured client_detail with the 70/30
grid pattern, and restyled methodology_form.

base.html sidebar's Agents row active-state extended to include
agent_detail.

No model changes, no new selectors, all form contracts preserved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Confirm**

```bash
git log --oneline -5
```

Expected: one new commit at the top of branch `management-screens`.

---

## Out of scope (named so we don't drift)

- Agent edit screen (Edit button on agent_detail links to `#`)
- Client edit/create/delete restyling (links route to existing untouched forms)
- Methodology delete flow
- Real data behind agent today's-load (uses placeholder bar logic)
- All / Active / Archived toggle on Agents and Methodologies lists (visual-only)
- Notifications popover, kebab menus, search modal (placeholders)
- Mobile layout

## Rollback

`git revert` of the commit produced by Task 11. No database, no service, no env changes.
