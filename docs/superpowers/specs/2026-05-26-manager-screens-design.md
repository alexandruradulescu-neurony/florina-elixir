# Manager Screens — Implementation Spec

**Date:** 2026-05-26
**Author:** Alex (with Claude)
**Status:** Approved (brainstorming) → pending writing-plans
**Builds on:** [Claude Design Foundation](2026-05-26-claude-design-foundation-design.md) (already implemented on branch `claude-design-foundation`)

---

## 1. Goal

Implement the three primary Manager screens — **Dashboard**, **Visits list**, and **Visit detail** — using the design system foundation. Full visual fidelity to the Claude Design export, with deterministic placeholders filling gaps where real data isn't available yet.

## 2. Locked decisions (from brainstorming)

| # | Decision | Rationale |
|---|---|---|
| 1 | All 3 screens in a single unified plan | Cross-screen primitives are shared; one branch ships a coherent visual story |
| 2 | Build every visual element from the design — fill data gaps with placeholders | User wants the full UI richness now; replacing placeholders with real data is a deliberate follow-up |
| 3 | Placeholders are deterministic from primary keys | Same record always shows the same numbers; looks real, easy to find and replace |
| 4 | Linear, primitives-first approach (Phase 1–4 in order, Dashboard first) | Dashboard exercises every primitive — building primitives once and validating them on the densest consumer reduces rework |
| 5 | No model changes, no new selectors | Existing selectors already return ~60% of what the JSX expects; placeholders fill the rest |
| 6 | Existing query params, POST forms, and URL routes preserved as-is | Behavior unchanged; only chrome and presentation change |

## 3. File layout

### Create

```
static/css/
└── screens.css                       Shared screen-flavored primitives + per-screen rules

voice/templates/voice/partials/
├── avatar.html                       Color-circle initial avatar
├── call_phase_icon.html              Pre (circle) / Post (diamond), done|live|todo
└── outcome_chip.html                 Title-cased chip variant

voice/
└── placeholders.py                   Deterministic placeholder helper functions
```

### Modify

- `voice/templates/voice/manager/dashboard.html` — full rewrite
- `voice/templates/voice/manager/visit_list.html` — full rewrite
- `voice/templates/voice/manager/visit_detail.html` — full rewrite
- `voice/views.py` — `SuperuserDashboardView`, `VisitListView`, `VisitDetailView` each gain a few lines that call `placeholders.py` helpers and inject results into context. No query changes, no permission changes.

### Don't touch

- `voice/models.py` — no model changes
- `voice/selectors.py` — no new selectors; consume the ones already there
- `voice/urls.py` — no URL changes
- Any other screen, view, form, or service

## 4. Placeholder strategy

A new module `voice/placeholders.py` defines pure functions that return mock data deterministically derived from a record's primary key. Examples:

```python
def visit_ministats(visit):
    """Mock post-call analytics. Replace when sentiment extraction lands.

    Returns a dict with keys: sentiment (0-100), sentiment_delta (str),
    talk_ratio (0-100), objections (int), champion (str).
    Deterministic from visit.id."""
    return {
        'sentiment': 60 + (visit.id % 30),
        'sentiment_delta': f'+{2 + (visit.id % 6)}',
        'talk_ratio': 40 + (visit.id % 30),
        'objections': visit.id % 4,
        'champion': ['Weak', 'Moderate', 'Strong', 'Champion'][(visit.id // 3) % 4],
    }
```

Every placeholder function has a docstring stating it is mock and naming the real-data path that would replace it. This makes follow-up replacement an obvious grep target.

The module also contains larger functions that pack multiple values into "extras" dicts consumed by each view:

- `dashboard_extras(context)` → adds `week_label`, `weekly_kpis_with_bars`, `recent_summaries_chips`, `today_date_str`, `agent_readiness_bars`, `next_visit_chip`.
- `visits_extras(context)` → adds `live_clients`, `at_risk_count`, `at_risk_label`, `crm_synced_count`, `crm_synced_pct`, per-visit `crm_state` and `agent_palette`.
- `visit_detail_extras(visit, pre_calls, post_calls)` → returns `kv_strip`, `attendees_list`, `pre_call_panel`, `post_call_panel`, `post_call_ministats`, `client_intel`, `intel_kpis`, `generated_prompts`.

Each view calls its `*_extras` once after building real context, then updates the context dict.

## 5. Phase 1 — Shared primitives

**Deliverable:** new CSS classes and partials that every screen consumes. Nothing renders yet; this phase is pure plumbing.

### CSS additions in `screens.css` (new file, ~250 lines)

- `.outcome-chip` (+ `-green`, `-cream`, `-rose`) — title-case label + 6 px dot, same geometry as `.pill` from foundation but title-cased.
- `.call-icon` base + `.call-icon-pre` (circle SVG mask) + `.call-icon-post` (diamond), with `.done`, `.live`, `.todo` color states.
- `.crm-dot` (+ `-synced`, `-pending`, `-error`) — 8 px filled circle.
- `.av-a` / `.av-b` / `.av-c` / `.av-d` / `.av-cyan` — avatar palette extensions. The base `.av` class already exists in `shell.css` (sidebar admin block); these add color-coded variants.
- `.profile-btn` — header utility row profile button (avatar + name + caret).
- `.toggle` — segmented pill switch container, supports List/Board and Week/Day.
- `.section-head` — section heading row above major cards (`<h2>` + optional "View all" link).
- `.next-pill` — cyan-50 pulsing pill for "Next visit in N min".
- `.breadcrumb` — Visit Detail header utility row.
- `.week-chip` — Dashboard / Visits header utility row navigator.

### Partials

- `avatar.html` — params: `initial`, `palette` (a|b|c|d|cyan), `size` (32 default | 36).
- `call_phase_icon.html` — params: `phase` (`pre`|`post`), `state` (`done`|`live`|`todo`).
- `outcome_chip.html` — params: `label`, `tone` (green|cream|rose).

### Verification (Phase 1)

- `python manage.py check` passes.
- `python manage.py collectstatic --dry-run --noinput | grep screens.css` finds it.
- No template renders are visibly different yet — Phase 1 is invisible until consumers ship.

## 6. Phase 2 — Dashboard

**View changes (`SuperuserDashboardView`):** call `placeholders.dashboard_extras(context)` after building real context. Pass `next_visit_chip` if `next_visit` exists.

**Template regions (top to bottom):**

1. **Header utility row** — search + notifications icon buttons only (already provided by `base.html`).
2. **Header page row** — `display_title = "Dashboard"`; `display_subtitle = today_date_str`; filter pill group `All | Today | This week | At risk` (default active = "Today"); primary CTA `+ New visit` (TODO: links to `visit_list` until a creation flow ships).
3. **Needs Attention card** — full width. `NEEDS ATTENTION` meta label + count badge; one `.alert-row` per item in `action_items` with amber icon, `lead` from message, `meta` from placeholder, "View →" link to detail if `visit_id` set.
4. **Stat row** — 4-column grid of `stat_card` partials: `Active` (`tone=cyan`), `Complete today`, `Pre-call done` (with `secondary` count), `Post-call done` (with `secondary` count). All sourced from `visit_summary`.
5. **Agent Readiness grid** — `.agents` 3-column grid. Per agent: 32 px avatar + name + methodology + status pill (cyan-filled `Live` / cream `Idle` / green `Ready`); 8-tile bar-stack from `agent_readiness_bars` (each tile 40 × 18, gap 4 px, color per slot: cyan-100 upcoming / zinc-950 completed / zinc-200 empty / rose-100 cancelled); footer with `TODAY` label and `"{done}/{total} · {placeholder_success}% success"`.
6. **60/40 split** —
   - **Left (60%)** Recent Summaries card. Header + "View all" link. 5 `.summary` rows from `recent_summaries`: 32 px avatar + `agent.name → client.name` + timestamp + 2-line truncated `post_call_summary` + outcome chips from placeholder.
   - **Right (40%)** This Week compact card. Header with `weekly.week_start..week_end` range. 3 KPI blocks (Visit completion, Call success, CRM sync) each = label + value + mini bar (pct from placeholder) + sub line. Bottom: 7-cell date strip (kept in markup but `display:none`-styled — preserves the design's structure for future activation).
7. **Today's Timeline table** — full-width `.tbl`. Columns: TIME (with pre/post call icons below), AGENT (avatar + name), CLIENT (name + industry), METHODOLOGY (method-pill), STATUS (status pill), kebab. Rows from `todays_visits`; in-progress row gets cyan-50 background.

**Phase 2 CSS additions in `screens.css`:** `.agents` grid, `.split`, `.summary` rows, `.alert-row`, `.kpi` block, `.t-row`/timeline, `.next-pill`, `.datestrip`, dashboard-specific `.section-head` placements.

## 7. Phase 3 — Visits list

**View changes (`VisitListView`):** call `placeholders.visits_extras(context)` after building real context. Existing query params (`date`, `agent`, `status`) and pagination preserved.

**Template regions (top to bottom):**

1. **Header utility row** — left: List/Board `.toggle` (List active, Board placeholder — toggle exists but doesn't switch view) + grid icon-btn. Center: `.week-chip` showing target week + chevrons (use existing `prev_date`/`next_date`). Right: search icon-btn + `.profile-btn` (current user, no menu).
2. **Header page row** — `display_title = "Visits"`; `display_subtitle = target_date.strftime('%A, %B %-d, %Y')`; filter pill group `All | Upcoming | Completed | Cancelled` (active from `status_filter`); primary CTA `+ New visit`.
3. **Stat row** — 4-column grid: `Total today`, `Active now` (with live dot if > 0, sub-line = first 1–2 live client names), `At risk` (with placeholder sub-line), `CRM synced` (`{n}/{total}` + `{pct}%`).
4. **Filter bar** — `.filterbar` with three dropdown pills (Agent, Status, Methodology — GET form submit), one search input (visual-only this pass), right-aligned "X of Y visits" count.
5. **Visits table** — `.vtable`. Columns: TIME (start–end 24h), AGENT (avatar from `agent_palette` placeholder + name), CLIENT (name + industry), METHODOLOGY (`.method-pill`), CALLS (pre + post `call_phase_icon`), STATUS (status pill from `visit.status`), CRM (`.crm-dot` from `crm_state` placeholder), kebab. Cancelled rows: strikethrough variant.
6. **Table footer** — `.vt-foot` with "Showing N visits for {target_date}" left + prev/next pagination buttons right (reuse `prev_date`/`next_date`).

**Phase 3 CSS additions in `screens.css`:** `.filterbar`, `.vtable`/`.vt-head`/`.vt-row`/`.vt-foot`, `.method-pill`, cancelled-strikethrough variant.

**Behavior notes:** Board toggle, methodology dropdown, search input, kebab menu are visual-only this pass. The methodology dropdown will be a real GET filter in a follow-up; the rest may stay placeholder indefinitely.

## 8. Phase 4 — Visit detail

**View changes (`VisitDetailView`):** call `placeholders.visit_detail_extras(visit, pre_calls, post_calls)` after building real context. The existing POST flow for `VisitManagerNotesForm` is preserved unchanged.

**Template regions:**

1. **Header utility row** — left: `.breadcrumb` (Visits / `{visit.start_time:%b %-d}` / `{client.name}`). Right: "Open in CRM" secondary button (links to `#` placeholder if `client.crm_id` exists, else absent), "Share" secondary button (placeholder), kebab.
2. **Header page row** — `display_title = client.name`. `display_subtitle` = `.metastrip` (mini-avatar + agent name + `Visit on {date} · {time_range}` + methodology inline pill + `SA-{visit.id:06d}`). Right side: status pill mapped from `visit.status`.
3. **Stepper** — 5-step from `context['steps']`. Per step: 32 px bubble + label + timestamp.
   - Done: `--green-100` fill + 16 px `--green-700` check; connector to next = `--green-700`.
   - Current: `--cyan-500` fill + 16 px white indicator; connector from previous = `--green-700`; connector to next = `--border-default`.
   - Pending: white fill + `--border-default` ring; no glyph.
   - Cancelled (terminal alt): `--rose-100` + `--rose-700` ban glyph.
4. **70/30 detail grid** — `.detail-grid` with `grid-template-columns: 1fr 320px`.
   - **Left column (`.detail-col`):**
     - **MetaCard** — 4-col `.kv-strip` from `kv_strip` placeholder.
     - **Attendees** — flex-wrap of `.att` pills from `attendees_list`.
     - **Pre-Call card** — `.callpanel` from `pre_call_panel` (thumb play + title + description + meta tags + Replay button) + transcript snippet block (`.snippet`, collapsed by default).
     - **Post-Call card** — `.callpanel` from `post_call_panel` + 4-col `.ministats` grid (Sentiment + delta, Talk ratio, Objections, Champion) from `post_call_ministats` placeholder.
     - **Debrief Summary** — prose paragraphs from `visit.post_call_summary`. Hidden when empty.
   - **Right rail (`.detail-side`, sticky):**
     - **Manager Notes** — form with `VisitManagerNotesForm` textarea, methodology select, Save button. Existing POST behavior unchanged; only styling changes.
     - **Client Intel** — paragraph from `client.ai_summary` (or placeholder), `intel-chips` array, `kpi-list` rows from `intel_kpis` placeholder.
     - **Generated Prompts** — collapsible `prompt-row` items from `generated_prompts` (empty entries skipped).

**Phase 4 CSS additions in `screens.css`:** `.breadcrumb`, `.metastrip`, `.stepper`, `.detail-grid`, `.dcard`, `.kv-strip`, `.att`, `.callpanel`, `.ministats`, `.notes`, `.intel-summary`/`.intel-chips`/`.kpi-list`, `.prompt-row`.

## 9. Verification

Pure visual + behavioral, no business-logic changes — no automated tests. Manual per-phase:

- **Phase 1:** static asset HTTP 200, `manage.py check` passes, no template visibly changes.
- **Phase 2:** visit `/dashboard/admin/`, confirm all 7 regions render. Spot-check: active in-progress row gets cyan-50 highlight; agent bar-stack is deterministic across refreshes; week date strip is in DOM but hidden.
- **Phase 3:** visit `/manager/visits/`. Walk date navigation, agent filter, status filter — confirm URLs preserve as GET params and the table updates. Confirm cancelled rows show strikethrough.
- **Phase 4:** visit `/manager/visits/<id>/` on visits in each lifecycle state (planned, pre-call, in-progress, post-call, complete). Verify stepper colors match state. POST the manager-notes form and verify the save flash + persisted values.

## 10. Out of scope (named so we don't drift)

- Board view (visits page toggle is visual-only — clicking Board does nothing)
- Search input on Visits page (visual-only)
- Notifications popover, kebab menus, Share modal (placeholders)
- New visit creation flow (CTAs link to `visit_list` for now; documented TODO)
- Replacing placeholders with real data — each placeholder docstring names its real-data path; that's a separate plan per area
- Mobile layout
- Replacing the legacy `Meeting` model usage anywhere
- Authenticated dashboard for non-superuser roles (sales agent has its own dashboard already; no changes here)
- Empty states beyond what the existing templates render (e.g., zero visits today shows a centered "No visits today" message in the timeline card — that's already handled adequately; no new empty-state illustrations)

## 11. Rollout & rollback

Per the foundation pass pattern: implement uncommitted in the working tree, commit on a branch at the end. Likely branch name: `manager-screens` (off `claude-design-foundation` so it consumes the foundation), or a continued commit on `claude-design-foundation` if the user prefers one branch for the whole redesign. Decision deferred to implementation kickoff.

Rollback: `git revert` of the phase commits. No database, no service, no environment changes.
