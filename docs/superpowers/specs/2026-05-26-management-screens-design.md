# Management Screens — Implementation Spec

**Date:** 2026-05-26
**Author:** Alex (with Claude)
**Status:** Approved (brainstorming) → pending writing-plans
**Builds on:** branch `manager-screens` (which has design foundation + Dashboard/Visits/VisitDetail and the bundled refactoring WIP)

---

## 1. Goal

Implement the three Manager management screens (Agents, Clients, Methodologies) plus their detail/edit views — six surfaces total spanning seven templates. The three list views have Claude Design references; the singles are designed here from the established vocabulary (Visit Detail's 70/30 grid pattern, the form-card pattern, etc.).

## 2. Locked decisions (from brainstorming)

| # | Decision | Rationale |
|---|---|---|
| 1 | Build a new Agent Detail view (read + small actions) PLUS restyle the existing create form | No detail view exists today; the list needs a target to link to |
| 2 | Restructure Client Detail to match the Visit Detail 70/30 grid pattern | Reuses the visual vocabulary already shipped; right rail handles intel/contacts/agents/CRM |
| 3 | Methodology single = restyle the existing create+edit form only | The card grid's "Edit methodology →" link already routes there |
| 4 | Linear primitives-first plan (Phase 1 shared CSS, Phase 2 lists, Phase 3 singles) | Same pattern as Foundation + Manager Screens passes |
| 5 | No model changes, no new selectors | Existing selectors + placeholders cover the data |
| 6 | Behavior preservation: form contracts, query params, redirects all unchanged | Pure visual + structural change |

## 3. File layout

### Modify

```
static/css/screens.css                            append ~280 lines of list/grid/form rules
voice/templates/voice/base.html                   add `agent_detail` to Agents row active-state check
voice/templates/voice/manager/
├── agent_list.html                               full rewrite (card grid → .atable)
├── agent_form.html                               full rewrite (restyle existing fieldsets)
├── client_list.html                              full rewrite (table → .ctable + search)
├── client_detail.html                            full restructure (70/30 grid)
├── methodology_list.html                         full rewrite (card grid → .mcard 2-col)
└── methodology_form.html                         full rewrite (restyle existing fieldsets)
voice/urls.py                                     add 1 line for new agent_detail URL
voice/views.py                                    add AgentDetailView (~40 lines) + one-line placeholders calls in 3 list views and the new detail view
voice/placeholders.py                             append helper functions: agents_extras, clients_extras, methodologies_extras, agent_detail_extras, client_detail_extras
```

### Create

```
voice/templates/voice/manager/
└── agent_detail.html                             NEW (~140 lines)
```

### Don't touch

- Models, forms, selectors
- Other screens already shipped (Dashboard, Visits, Visit Detail)
- Foundation files (tokens.css, shell.css, icons)
- `agent_edit`, `client_edit`, `client_create`, `client_delete`, methodology delete flows

## 4. Phase 1 — Shared CSS additions

Append ~280 lines to `static/css/screens.css`. Four chunks:

### 4.1 `.atable` (~70 lines, source: `agents-list-styles.css`)

- `.atable` — base table card (white, hairline border, 16 px radius, no inner padding)
- `.atable thead th` — uppercase 10 px meta column headers, muted
- `.atable .who` — flex of avatar + name + email stack
- `.atable .loadbar` + `.fill` — 120 × 8 px progress bar; fill width driven by inline `style="width: N%"`
- `.atable .num` + `.dim` — tabular numbers for done/total
- `.atable .more` — 32 px circular `...` overflow button, opacity 0 → 1 on row hover

The `.meth-pill` class already exists from the Visits CSS — reused as-is.

### 4.2 `.ctable` + `.clients-search` (~80 lines, source: `clients-directory-styles.css`)

- `.clients-search` — 44 px tall pill-shaped search form above the table
- `.ctable` — same card geometry as `.atable`
- `.ctable .client` — name (`.nm`) + domain (`.dom`) two-line stack
- `.ctable .visits` — count (`.n`, weight 800) + last-visit secondary (`.last`)
- `.ctable .intel` — two-row dot stack: `.row.ai`, `.row.crm`, both with `.dot` + label + optional `.miss` muted variant
- `.ctable .synced` — colored dot + relative time; `.fresh` (green-700 dot) vs `.stale` (amber-800 dot)
- `.ctable .more` — same overflow button as `.atable`

### 4.3 `.method-grid` + `.mcard` (~80 lines, source: `methodologies-grid-styles.css`)

- `.method-grid` — `grid-template-columns: repeat(2, minmax(0, 1fr))`, 20 px gap
- `.mcard` — card with internal vertical rhythm (16 px gap between sections)
- `.mcard.is-inactive` — zinc-50 background + muted text variant
- `.mcard .top` — header row: name `h2` + optional `.default-badge` (small cyan-100 / cyan-700 pill labeled "Default") + status chip (`.pill-green` or `.pill-cream`)
- `.mcard .desc` — 2-line clamp description, font-tile
- `.mcard .stats` — 2-column mini-stat grid:
  - `.mini` — bordered panel with `.l` (meta label) + `.v` (24 px weight-800 number)
- `.mcard .indicators` — two `.ind-row` rows (PDF status, AI summary status)
  - `.ind-row.on` — green-700 dot + strong text
  - `.ind-row.off` — zinc-300 dot + muted text
- `.mcard .foot` — `.edit-link` "Edit methodology →" in cyan-600

### 4.4 Form-page chrome (~50 lines, NEW — no design package analog)

For agent create/edit and methodology create/edit. Reuses tokens + auth-card input patterns but scopes to authenticated pages.

- `.form-layout` — `display: grid; grid-template-columns: 1fr 320px; gap: 16px;` (same as `.detail-grid`)
- `.form-card` — white card, 16 px radius, hairline border, 32 px padding
- `.form-fieldset` — `<fieldset>` reset + `<h3>` legend treatment matching `.dcard h3`
- `.form-row` — `display: flex; flex-direction: column; gap: 6px; margin-bottom: 20px;` (label + input + helptext stack)
- `.form-row label` — strong, 12 px, dark
- `.form-row input[type=text], input[type=email], input[type=password], input[type=tel], input[type=url], textarea, select` — 40 px height (textarea/select auto), hairline border, 8 px radius, focus border cyan-500
- `.form-row textarea` — min-height 120 px, `resize: vertical`
- `.form-row .helptext` — muted 12 px below the input
- `.form-row .field-error` — already exists in shell.css from foundation, reused here
- `.form-row input[type=checkbox]` — sits inline with its label using a `.checkbox-row` wrapper
- `.form-actions` — flex row of Save (primary) + Cancel (secondary) at the bottom of the form sidebar
- `.form-sidebar` — same as `.detail-side` (sticky, gap-16, position-sticky-top-24)

## 5. Phase 2 — Three list views

### 5.1 Agents list

**View additions:** `AgentManagementView` calls `placeholders.agents_extras(context)`. Adds per-agent:
- `avatar_palette` (from existing `agent_palette`)
- `today_load_bars` (8-slot bar-stack from existing `agent_readiness_bars`-like algo over today's visits)
- `success_pct` (real if `call_success_rate` present, else placeholder 55-90)

**Template regions:**
1. Header utility row — All / Active / Archived toggle (visual-only), search + notif buttons
2. Header page row — title "Agents", subtitle "{agent_count} agents · {configured_count} configured", `+ New agent` primary CTA
3. Stat row — 4 cards: Total agents, Configured (configured_count), Live now (placeholder), Avg success (placeholder)
4. `.atable` — columns: Agent (avatar + name + email), Methodology (`.meth-pill`), Today's load (`.loadbar` + `done/total`), Done, Success %, kebab linking to `voice:agent_detail`

### 5.2 Clients list

**View additions:** `ClientListView` calls `placeholders.clients_extras(context)`. Adds per-client:
- `domain_short` (strip protocol/www prefix for display)
- `intel_ai_on` (from existing `has_summary`)
- `intel_crm_on` (from `client.crm_id` truthy)
- `synced_fresh` (inverse of existing `is_stale`)
- `synced_ago` (relative time string)

Context-level: `clients_with_crm_count`, `clients_with_summary_count`, `clients_stale_count`.

**Template regions:**
1. Header utility row — search + notif buttons
2. Header page row — title "Clients", subtitle "{total_count} clients · {with_summary} with AI summary", `+ New client` primary CTA
3. Stat row — 4 cards: Total, With AI Summary, With CRM, Stale (>7d)
4. `.clients-search` form (GET `?q={search}`)
5. `.ctable` — columns: Client (name + domain), Industry, Visits (count + last date), Agents, Intel (AI + CRM dot stack), Last Synced (dot + ago string), kebab linking to `voice:client_detail`

### 5.3 Methodologies list

**View additions:** `MethodologyListView` calls `placeholders.methodologies_extras(context)`. Adds per-methodology:
- `desc_short` (truncated description, ~120 chars or first 2 sentences)
- `status_label` ("Active" / "Inactive")
- `status_tone` ("green" / "cream")

**Template regions:**
1. Header utility row — All / Active / Archived toggle (visual-only), search + notif buttons
2. Header page row — title "Methodologies", subtitle "{total_count} methodologies · {active_count} active", `+ New methodology` primary CTA
3. Stat row — 3 cards: Total, Active, With PDF
4. `.method-grid` of `.mcard`:
   - Top: name h2 + optional `.default-badge` (when `is_system_default`) + status chip
   - `.desc` (2-line clamp)
   - `.stats` mini-grid: Agents using + Visits using
   - `.indicators`: PDF attached (on/off) + AI Summary (on/off)
   - `.foot`: "Edit methodology →" link to `voice:methodology_edit`

## 6. Phase 3 — Four single views

### 6.1 Agent Detail (`manager/agent_detail.html`) — NEW

**New URL:** `manager/agents/<int:agent_id>/` named `agent_detail`.

**New view (`AgentDetailView`):** loads the agent, fetches recent visits (existing selector `get_agent_visits`), recent calls (`CallAttempt.objects.filter(visit__agent=agent)...`), calls `placeholders.agent_detail_extras(agent, recent_visits, recent_calls)` which returns:
- `agent_kv_strip` — 4 key-value items: Email, Phone, Methodology, Pipedrive ID
- `agent_stat_row` — 4 stats: Visits today, Completed today, Active visits, Avg success rate
- `today_load_bars` — 8-slot bar-stack
- `recent_visits_enriched` — list with status/palette/client info attached
- `recent_calls_enriched` — list with palette/status_pill_variant attached
- `agent_status_label` + `agent_status_variant` — derived from existing readiness-status enum (Live/Ready/Idle/Issue)

**Template regions (~140 lines):**
1. Header utility row — breadcrumb (`Agents` / `{agent name}`)
2. Header page row — display_title = agent full name; metastrip with email + phone + methodology pill + agent ID code (`AG-{id:06d}`); right side: status pill, "Edit" secondary button (links to `#` — agent edit not built), kebab
3. Stat row — 4 stat_card partials from `agent_stat_row`
4. 70/30 detail grid:
   - **Left:** Meta card (4-col kv-strip), Today's Load card (8-slot bars + summary text), Recent Visits table (`.tbl` with rows from `recent_visits_enriched`)
   - **Right rail (sticky):** Configuration card (3-row indicator list for phone/methodology/pipedrive), Recent Calls card (list of 5 most recent calls with status pill), Methodology card (name + link to methodology edit if assigned)

**Base.html change:** active-state check for the Agents sidebar row gains `agent_detail` in its OR-chain.

### 6.2 Agent Form (`manager/agent_form.html`) — restyle

Existing form (3 fieldsets) restyled into the new design system. Form contract preserved (`AgentCreateForm` from `voice/forms.py`).

**Template regions:**
1. Header utility row — breadcrumb (`Agents` / `New agent`)
2. Header page row — display_title = "New agent". No filter pills. No header_actions (the form's Save lives in the sidebar).
3. Content — `.form-layout`:
   - Left: `.form-card` with 3 `.form-fieldset` blocks: **Account** (username, first_name, last_name, email), **Password** (password1, password2), **Configuration** (phone_number, pipedrive_user_id)
   - Right: `.form-sidebar` with `.form-actions` (Save + Cancel) and a separate `.card` with the existing "What happens next" numbered checklist

Field rendering: explicit `<label>` + `<input>` per field, NOT `{{ form.as_p }}`. Per-field errors use `.field-error` class. Helper text from the form's help_text shown as `.helptext`.

### 6.3 Client Detail (`manager/client_detail.html`) — restructure

**View additions:** `ClientDetailView` calls `placeholders.client_detail_extras(client_detail)`. Adds:
- `client_kv_strip` — 4-col meta: Industry, Domain, CRM ID, Last Synced relative time
- `client_stat_row` — 4 stats: Total visits, Completed, Completion %, Active agents (existing fields)
- `agents_enriched` — `[{agent, avatar_palette, methodology}, ...]`
- `recent_calls_enriched` — `[{call, visit, agent, palette, status_pill_variant}, ...]`

**Template regions (~180 lines):**
1. Header utility row — breadcrumb (`Clients` / `{client name}`)
2. Header page row — display_title = client.name; metastrip with industry + domain + CRM ID code + last-synced relative time; right: "Edit" secondary button (links to existing `voice:client_edit`), kebab
3. Stat row — 4 stat_cards from `client_stat_row`
4. 70/30 detail grid:
   - **Left:**
     - Meta card (4-col kv-strip)
     - Visit History table (`.tbl` with columns: Date, Agent, Methodology, Status, row link to visit_detail)
     - Recent Calls card (list with status pills + relative timestamps)
   - **Right rail (sticky):**
     - AI Summary card (`client.ai_summary` prose, or a placeholder summary)
     - Contacts card (list of `client.contacts` items rendered as small cards: name + email + phone + role)
     - Assigned Agents card (per-agent: avatar + name + methodology pill, links to agent_detail)
     - CRM Data card (CRM ID, deal count, interaction count, last synced timestamp)

### 6.4 Methodology Form (`manager/methodology_form.html`) — restyle

Same form contract (`MethodologyForm`). 3 fieldsets restyled.

**Template regions:**
1. Header utility row — breadcrumb (`Methodologies` / `New methodology` or `{methodology.name}`)
2. Header page row — display_title = "New methodology" or "Edit {methodology.name}"
3. Content — `.form-layout`:
   - Left: `.form-card` with 3 `.form-fieldset` blocks: **Basic Information** (name, description, is_active checkbox), **Source Material** (file upload, with current-file preview if editing), **AI Summary** (textarea, with regenerate hint)
   - Right: `.form-sidebar` with `.form-actions` (Save + Cancel) and (when editing) a `.card` showing the current methodology's PDF/AI/Active status indicators

## 7. Verification

Manual smoke per phase, no automated tests.

- **Phase 1:** `manage.py check` passes; `screens.css` line count grew by ~280; no visible template changes yet.
- **Phase 2 (Lists):**
  - `/manager/agents/` — `.atable` rows with avatars + methodology pills + load bars + success %; clicking the kebab navigates to agent_detail
  - `/manager/clients/` — `.clients-search` + `.ctable` rows; AI/CRM intel dots reflect real state; freshness dot color matches `is_stale`; kebab navigates to client_detail
  - `/manager/methodologies/` — 2-col `.method-grid` with `.mcard` per methodology; default methodology has `.default-badge`; edit link routes correctly
  - Sidebar's active row matches the page being viewed
- **Phase 3 (Singles):**
  - `/manager/agents/<id>/` — Agent Detail renders; sidebar Agents row stays active
  - `/manager/agents/add/` — restyled agent create form; Save submits and creates an agent (POST behavior unchanged); errors display via `.field-error`
  - `/manager/clients/<id>/` — restructured client detail with 70/30 grid; right rail sticky on scroll
  - `/manager/methodologies/<id>/edit/` and `/manager/methodologies/add/` — restyled methodology form; Save submits and persists; file upload still works
- **Cross-cutting:** `manage.py check` passes after each phase; all `/static/css/screens.css` and icon SVGs return 200.

## 8. Out of scope (named so we don't drift)

- Agent edit screen (no `agent_edit` URL/template exists; Edit button placeholder)
- Client edit/create/delete form restyling (existing functionality untouched)
- Methodology delete flow
- Real data behind agent today's-load (uses placeholder bar-stack)
- "All / Active / Archived" toggle on Agents and Methodologies lists (visual-only)
- Notifications popover, kebab menus, search modal, share modal (placeholders)
- Mobile layout (secondary per design spec)
- Sales-agent role screens (My Schedule / Calendar Sync / Profile already have their own treatment)

## 9. Rollout & rollback

Follow established pattern: stay uncommitted through Phases 1–3, then create branch `management-screens` off `manager-screens` and commit. Rollback is `git revert` of the single commit. No database, no service, no env changes.
