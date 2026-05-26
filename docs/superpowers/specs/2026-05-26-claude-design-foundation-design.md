# Claude Design Foundation — Implementation Spec

**Date:** 2026-05-26
**Author:** Alex (with Claude)
**Status:** Approved (brainstorming) → pending writing-plans
**Source design package:** `sales-assistant-calendar-design-system` (Claude Design export, 2026-05-26)

---

## 1. Goal

Replace the current Tailwind/DaisyUI shell of the Sales Assistant Django app with the new "Editorial Minimalism × Warm Scheduling" design system from the Claude Design export. This pass delivers the **foundation only**: design tokens, fonts, icons, the new `base.html` shell (264 px white sidebar + two-row header), and a small set of reusable component partials. No screen-level redesigns are in scope.

The new shell becomes visible on every authenticated page immediately. Un-redesigned screens will look stylistically broken until their content is rebuilt in later passes — this is an accepted transition cost.

## 2. Locked decisions (from brainstorming)

| # | Decision | Rationale |
|---|---|---|
| 1 | Foundation only this pass; screens follow in later passes | Lower risk; allows the user to see the shell live before committing to screen work |
| 2 | New shell visible on every page (replace `base.html`) | Avoids a feature-flag/coexistence complexity tax |
| 3 | Drop Tailwind CDN + DaisyUI; hand-rolled CSS like the design package | The design spec explicitly rejects framework defaults ("anti-slop"); the design ships its own tokens |
| 4 | Accept ugly transition for un-redesigned screens | Forces fast redesign cadence; avoids transitional CSS that lingers |
| 5 | Both Manager and Sales Agent roles get the new shell with role-aware nav | Consistent product look; one shell, two nav configurations |
| 6 | Sidebar matches design exactly: Dashboard, Visits, Calendar, Live Agent \| Agents, Clients, Methodologies, Calls. Prompts and Logs drop from sidebar (still reachable by URL) | Matches the design package; Prompts/Logs are internal-feeling and can be moved under Settings later |

## 3. File layout

### Create

```
static/
├── css/
│   ├── tokens.css      copied from design package's assets/colors_and_type.css
│   ├── icons.css       copied from design package's assets/icons.css
│   └── shell.css       new: sidebar + header + canvas + component class styles
└── icons/              copied from design package's assets/icons/ (24 SVG files)

voice/templates/voice/partials/
├── status_pill.html    §7.3 of the design spec
├── count_badge.html    §7.4
└── stat_card.html      §7.5
```

Fonts load from Google Fonts CDN — no local font files. The italic-Nunito TTF in the design package is not needed (the product does not use italic Nunito).

### Modify

- `voice/templates/voice/base.html` — full rewrite.
- `voice/templates/voice/login.html`, `voice/templates/voice/logged_out.html` — unauthenticated screens. Repaint the centered-card content to use new tokens (white card, hairline border, 16 px radius, Nunito) instead of Tailwind classes. Not a redesign — same layout, new tokens.
- `voice/templates/voice/home.html` — authenticated post-login placeholder. Minimal patch: replace Tailwind-styled content body with a small "Welcome, &lt;name&gt;" card built from the new tokens. Stays a placeholder.

### Don't touch

- Every other template (22 files) — they break visually, get redesigned in later passes.
- `voice/views.py`, `voice/urls.py`, `voice/models.py`, `voice/services/` — no Python changes in this pass.

### Delete

Nothing. Tailwind/DaisyUI script + style tags are removed from `base.html`; class names in other templates become dead string content with no effect.

## 4. `base.html` structure

### 4.1 Loaded assets

```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Nunito:wght@500;700;800&family=Nunito+Sans:wght@600;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="{% static 'css/tokens.css' %}">
<link rel="stylesheet" href="{% static 'css/icons.css' %}">
<link rel="stylesheet" href="{% static 'css/shell.css' %}">
```

No Tailwind. No DaisyUI. No CDN scripts beyond Google Fonts.

### 4.2 Block contract (the API screens fill)

```django
{% block title %}{% endblock %}             {# browser tab title #}

{% block header_utility %}{% endblock %}    {# top header row content (optional, usually empty) #}

{% block display_title %}{% endblock %}     {# 32px Nunito 800 page title #}
{% block display_subtitle %}{% endblock %}  {# optional small line under the title #}
{% block header_filters %}{% endblock %}    {# centered filter pill group #}
{% block header_actions %}{% endblock %}    {# right-side: round buttons, primary CTA #}

{% block content %}{% endblock %}           {# main canvas content #}
```

The old shell's `{% block page_title %}` and `{% block page_header %}` are not preserved. Old templates that override them will render with a blank header — accepted transition cost (see §2 row 4).

### 4.3 Sidebar — role-aware

Fixed left, 264 px wide, white background, 1 px right hairline.

**Wordmark block (top):** 36 px cyan rounded-square avatar with white "S," + "Sales Assistant" (Nunito 700, 16 px) over the role label (Nunito 500, 12 px, muted) — "Manager" if `user.is_superuser`, "Sales Agent" if `user.is_sales_agent`.

**For superuser:**
- Group: `OVERVIEW` — Dashboard, Visits (count badge if `unread_visits_count` is in context), Calendar, Live Agent
- Group: `MANAGE` — Agents, Clients, Methodologies, Calls

**For sales agent:**
- Group: `OVERVIEW` — My Schedule, Calendar Sync
- Group: `ACCOUNT` — Profile

**Bottom block:**
- Settings row (superuser only, links to `global_settings`)
- Admin block: 32 px cyan rounded-square avatar with user initial, full name (Nunito 700, 14 px), "Logout" link below in 12 px muted.

**Active-state detection:** each nav row defines a tuple of URL names it activates on (e.g., the Visits row activates on `visit_list`, `visit_detail`, `visit_create`). Match `request.resolver_match.url_name` in the template. Active row = full pill, `--zinc-950` background, white icon and label.

**Hover state:** `--zinc-100` row background, no other change.

### 4.4 Header — two rows

**Row 1 (utility, ~64 px):**
- Left: optional `header_utility` block content (most pages leave empty).
- Right: round search button (40 × 40 white pill, hairline border, search icon at 16 px) + round notifications button (same dimensions, comment-alt-dots icon). Both placeholders this pass — no behavior, just chrome.

**Row 2 (page-action, ~72 px):**
- Left: `display_title` in 32 px Nunito 800, optional `display_subtitle` in 14 px Nunito Sans 600 muted underneath.
- Center: `header_filters` slot — typically a pill group.
- Right: `header_actions` slot — typically `+ New <noun>` primary CTA.

### 4.5 Unauthenticated branch

The current shell renders unauthenticated requests as a centered card with no sidebar. We keep that branch — login, logged_out, password-reset etc. continue to render as a centered card on `--bg-canvas`, but the card uses new tokens (white bg, hairline border, 16 px radius) instead of Tailwind classes.

### 4.6 Messages framework (toasts)

Current shell renders Django `messages` as DaisyUI alerts. New shell renders them as a fixed top-right stack of zinc cards with hairline border, color-keyed by tag using the same variants as `status_pill` (info → cyan, success → green, warning → amber, error → rose). No DaisyUI, no JavaScript framework — just static CSS positioning.

## 5. Component partials

Three Django includes. Each is a small named API; pages call them via `{% include "voice/partials/<name>.html" with ... %}`. No per-page variant invention — extending a component means editing its partial + `shell.css`, not duplicating it.

### 5.1 `status_pill.html` — §7.3 of the design spec

**Parameters:**
- `variant` (required) — one of `cream`, `cyan`, `cyan-filled`, `green`, `rose`, `amber-warning`
- `label` (required) — Title Case string
- `glyph` (optional) — icon name; if set, renders 12 px on the right instead of the left dot

**Visual:** 24 px tall pill, 12 px Nunito 700 label. Default left treatment: 6 px colored dot. If `glyph` is set, drop the dot and render the glyph on the right. Never both.

**`cyan-filled`** is the only filled variant (white text on `--cyan-500` background) — used exclusively for "Active / live now."

### 5.2 `count_badge.html` — §7.4

**Parameters:**
- `count` (required) — integer

**Visual:** 16–18 px tall pill, `--zinc-950` fill, white 11 px label, no border, no shadow. Renders nothing if `count` is `0` or falsy. Right-aligned by parent context.

### 5.3 `stat_card.html` — §7.5

**Parameters:**
- `label` (required) — string, rendered ALL CAPS
- `value` (required) — string or number
- `tone` (optional) — `default` (zinc-950 number), `green`, `cyan`, `rose`
- `secondary` (optional) — small inline value like `+6 wk` or `1/1`

**Visual:** white card, 16 px radius, hairline border, 24 px padding. Top = 10 px meta label, letter-spaced, muted. Bottom = 32 px Nunito 800 number tinted by `tone`. Optional secondary inline at 14 px Nunito 600 muted.

**Explicitly forbidden inside this component:** sparklines, progress bars, right-side chips. Screens that need those build their own card (e.g., the dashboard's "This Week" KPI card is a separate component, out of scope for this pass).

### 5.4 Table styling — CSS classes, not a partial

Tables are styled via classes in `shell.css` (`.tbl`, `.tbl-head`, `.tbl-row`, `.tbl-cell`, `.tbl-meta`) rather than a Django include — row iteration composes poorly with `{% include %}`. Header row 48 px, body row 56 px, hairline bottom border per row, hover background `--zinc-50`. Screens write their own `<table>` markup using these classes.

## 6. Icons

The design ships icons as a CSS sprite. Usage in templates:

```html
<span class="ic ic-grid"></span>
<span class="ic ic-plus"></span>
```

All 24 icons from the Flaticon UIcons filled-rounded family are copied as a unit. No individual icon imports. Sized via CSS classes (`ic-12`, `ic-16`, `ic-20`) or inline width/height.

Pre-call markers are circles, post-call markers are diamonds (convention from §10 of the design spec) — relevant when we get to Visit Detail, not in this pass.

## 7. Verification

Pure visual change, no business logic — no automated tests. Manual checks:

### Smoke (must pass)

1. `python manage.py runserver 0.0.0.0:8003` starts without template errors.
2. Visit `/` as superuser: new sidebar and two-row header render; no 404s in browser console for static assets; Nunito + Nunito Sans visible in network tab.
3. Visit `/` as sales agent: role-aware nav shows the 3 agent items in the same visual style.
4. Visit `/login` unauthenticated: centered card on `--bg-canvas`, no Tailwind class leakage.
5. Clicking each sidebar row navigates to its page and the corresponding row turns into the black pill.
6. Triggering a Django message (e.g., login flash) renders the toast in the new style, color-keyed by tag.

### Expected-ugly (NOT bugs)

- Every screen with un-redesigned content (visit_list, client_detail, every form, settings, logs, prompts) renders the new shell with bare/unstyled content inside. This is the transition cost from decision row 4.

### Known transition issues to call out, not fix

- Templates that override the old `{% block page_title %}` / `{% block page_header %}` render with a blank header. These will be repaired when each screen is redesigned in its own pass.
- DaisyUI classes used inline in template bodies (e.g., `alert alert-success`) have no effect. Same fix path.

## 8. Explicitly out of scope

Naming these so we don't drift mid-implementation:

- Mobile layout. Spec says secondary; no investment unless asked.
- Any screen redesign (Dashboard, Visits, Visit Detail, Calendar, Live Agent, Calls, Clients, Agents, Methodologies).
- Dashboard's "This Week" KPI card with progress bars (§7 doesn't define it — a screen-specific card).
- Agent Readiness card (§7.7) and Recent Summary card (§7.8) — screen-specific to Dashboard.
- Visit lifecycle stepper (§7.6) — screen-specific to Visit Detail.
- Notifications popover, search modal, command palette behavior — header buttons are visual placeholders only.
- Profile dropdown menu — admin block "Logout" is a direct link.
- Any Python changes (views, URLs, models, services).
- Removal of `voice_tags` template tag library — kept in case other templates use other filters from it.

## 9. Rollout & rollback

This is a single PR / single commit family. Rollback is `git revert` of the merge commit. No database changes, no service changes, no feature flag — pure template + static asset change.

The first deploy will show un-redesigned screens in their broken-transition state to every user. That's expected and was the explicit choice in brainstorming decision row 4.
