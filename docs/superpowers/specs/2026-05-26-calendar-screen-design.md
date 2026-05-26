# Calendar Screen — Implementation Spec

**Date:** 2026-05-26
**Author:** Alex (with Claude)
**Status:** Approved (brainstorming) → pending writing-plans
**Builds on:** branch `management-screens` (Foundation + Manager screens + Management screens)

---

## 1. Goal

Replace the existing Week/Month calendar with a redesigned Week+Day calendar matching the Claude Design package, including event chips with state coloring, a 7-day grid for Week view, an hour-by-hour stream + mini-calendar sidebar for Day view, and a status filter pill group that visually dims non-matching events.

## 2. Locked decisions (from brainstorming)

| # | Decision | Rationale |
|---|---|---|
| 1 | Ship Week + Day views; drop Month | Design package shows only Week and Day; Month isn't designed and adds maintenance |
| 2 | Click an event chip → navigate to `/manager/visits/<id>/` | Consistent with list views; no JS modal needed |
| 3 | "+ New" button and empty-slot clicks → placeholder `#` | Visit creation flow isn't built yet; this stays consistent with other screens |
| 4 | Linear primitives-first approach (CSS → view → template) | Same pattern as previous passes |
| 5 | Single template with mode branching (`{% if view_mode == 'week' %}…{% else %}…{% endif %}`) | Avoids chrome duplication across two templates |
| 6 | No JS framework for filtering; CSS-only via `data-filter` attribute on `.calendar-body` and `?filter=` query param | Keeps it simple and SSR-friendly |

## 3. File layout

### Modify

```
static/css/screens.css                                   append ~250 lines
voice/views.py                                           extend VisitCalendarView (~30 lines)
voice/placeholders.py                                    append calendar_extras helper (~150 lines)
voice/templates/voice/manager/visit_calendar.html        full rewrite (~250 lines)
```

### Create

Nothing new. No new URL, no new view class.

### Don't touch

- Models, selectors, urls.py
- Other screens (Dashboard, Visits, Visit Detail, Agents, Clients, Methodologies)
- Foundation files (tokens.css, shell.css, icons)

## 4. Phase 1 — Calendar CSS additions

Append ~250 lines to `static/css/screens.css`:

### 4.1 Top bar + filter bar tweaks (~30 lines)
- `.cal-topbar` — 64 px white bar reusing `.toggle`, `.icon-btn`, `.profile-btn`
- `.cal-nav` — centered prev/next + label group
- `.cal-nav-label` — Nunito 700, 13 px, color `--fg-strong`
- `.cal-filterbar` — uses existing `.hdr-page` chrome; filter pill group reuses `.filters`

### 4.2 Event chip (~60 lines)
- `.event-chip` — 4 px radius, 5 px×6 px padding, `--shadow-tile`
- `.event-chip .top` — flex row: `.time` (11 px Nunito Sans 700) + optional `.state-icon`
- `.event-chip .title` — 13 px Nunito Sans 700, single-line truncated
- `.event-chip.short` — Week-mode variant; hides `.title`
- State variants:
  - `.event-chip-upcoming` — `--cyan-500` bg, white text, dim shadow
  - `.event-chip-completed` — `--green-100` bg, `--green-700` text
  - `.event-chip-cancelled` — `--rose-100` bg, `--rose-700` text
  - `.event-chip-replanned` — `--amber-100` bg, `--zinc-950` text

### 4.3 Week grid (~60 lines)
- `.week-grid` — flex column, 6 px gap between week rows
- `.week-row` — `grid-template-columns: repeat(7, 1fr)`, 6 px gap
- `.week-row.this-week` — `--cyan-50` background with `.this-week-badge` pinned top-left
- `.day-cell` — white card, 8 px radius, hairline border, 8 px padding, min-height 120 px
- `.day-cell .dow-line` — flex row: `.dow` (10 px Nunito 800 uppercase muted) + `.dnum` (16 px Nunito 800)
- `.day-cell .dnum.today-circle` — 24 px circle with `--orange-500` background, white text
- `.day-cell .events` — flex column, 6 px gap, stacks event chips
- `.day-cell.empty .no-events` — centered muted "No events" text with 30 px top padding

### 4.4 Day stream + aside (~70 lines)
- `.day-layout` — `grid-template-columns: 1fr 320px`, 16 px gap
- `.day-stream` — flex column
- `.hour-row` — `grid-template-columns: 60px 1fr`, min-height 56 px, hairline top border
- `.hour-row .time-label` — right-aligned, 11 px monospace, muted, top-aligned
- `.hour-row .slot` — flex column, 6 px gap; empty slots render as just empty padding
- `.day-aside` — sticky right rail, position: sticky, top: 24 px
- `.mini-cal` — bordered card, 12 px radius, 16 px padding
- `.mini-cal-head` — flex row: prev button + month label + next button
- `.mini-cal-grid` — 7-column grid, header DOW row + 6 numeric rows
- `.mini-cal-day` — 32 × 32 px cell, centered numeral
- `.mini-cal-day.dim` — outside current month, muted
- `.mini-cal-day.today` — `--cyan-200` circle background
- `.mini-cal-day.selected` — `--cyan-500` fill, white text
- `.day-overview` — small `dcard` with visit count summary

### 4.5 Filter dimming (~10 lines)

CSS-only dimming via `[data-filter]` attribute:

```css
.calendar-body[data-filter="upcoming"] .event-chip:not(.event-chip-upcoming) { opacity: 0.35; }
.calendar-body[data-filter="completed"] .event-chip:not(.event-chip-completed) { opacity: 0.35; }
.calendar-body[data-filter="cancelled"] .event-chip:not(.event-chip-cancelled) { opacity: 0.35; }
```

`data-filter="all"` (default) doesn't dim anything.

## 5. Phase 2 — View extension + placeholder helper

### 5.1 `VisitCalendarView` changes

In `voice/views.py`:

1. **Accept `view=day` and drop `view=month`.** Update the GET param parsing:
   ```python
   view_mode = request.GET.get('view', 'week')
   if view_mode == 'month':
       return redirect(f'{request.path}?view=week&date={target_date}')
   if view_mode not in ('week', 'day'):
       view_mode = 'week'
   ```

2. **Branch on view_mode for data fetching:**
   ```python
   if view_mode == 'day':
       visits_for_day = list(get_visits_for_range(target_date, target_date, agent=agent_filter_obj))
       context['visits_for_day'] = visits_for_day
       prev_date = target_date - timedelta(days=1)
       next_date = target_date + timedelta(days=1)
   else:  # week
       # existing 7-day-week logic preserved
       prev_date = target_date - timedelta(days=7)
       next_date = target_date + timedelta(days=7)
   ```

3. **Accept `filter` query param** (`all` | `upcoming` | `completed` | `cancelled`) and pass as `status_filter` in context (CSS uses it to dim non-matching chips).

4. **Call helper** before render:
   ```python
   placeholders.calendar_extras(context)
   return render(request, 'voice/manager/visit_calendar.html', context)
   ```

### 5.2 `placeholders.calendar_extras(context)` helper

Adds these context keys:

- `month_label` — e.g., `"April 2026"` (target_date's month + year, used as the page title)
- `nav_label` — `"This week"` for Week mode; `"Today"` if target date is today in Day mode, else `"Day"`
- `today_iso` — string of today's date in YYYY-MM-DD (for the `?date=` link on "Today" anchor if added later)

For **Week mode** (when `context['weeks']` exists):
- For each week in `weeks` and each day in that week, enrich the day's visits list with:
  - `visit` — the Visit object
  - `state` — `'upcoming'`, `'completed'`, `'cancelled'`, or `'replanned'` derived from `visit.status` plus the placeholder rule:
    - `COMPLETE` → `completed`
    - `(visit.id % 13) == 0` → `cancelled` (placeholder — no CANCELLED enum exists)
    - `(visit.id % 17) == 0` → `replanned` (placeholder)
    - else → `upcoming`
  - `time_range` — e.g., `"09:00-10:00"`
  - `title` — `"{client.name} – {visit.title}"` (truncated to 40 chars for short chips)
- For each week, add `is_current_week` boolean

For **Day mode** (when `context['visits_for_day']` exists):
- Build `hour_buckets` — list of `{hour_label, hour, events: []}` covering the visible hour range. Default 09:00–18:00, extended to include earliest/latest visit hour if any visits fall outside that range.
- Each visit is placed in the bucket matching its start hour.
- Each event in the bucket has the same enriched dict shape as Week mode.
- Build `month_grid` — list of 6 weeks × 7 days for the mini-calendar of the target date's month. Each cell: `{day_num, iso, in_month, is_today, is_selected}`.

### 5.3 Existing behavior preserved
- `agent` query param keeps working (filter dropdown stays in the page-action row)
- `prev_date` / `next_date` continue to drive pagination
- POST behavior — none (calendar is read-only)

## 6. Phase 3 — Template rewrite

Full rewrite of `voice/templates/voice/manager/visit_calendar.html` with mode-branching. Single template, ~250 lines.

### Block contract

- `{% block title %}` — "Calendar — Sales Assistant"
- `{% block header_utility %}` — view toggle + prev/next navigator
- `{% block display_title %}` — `{{ month_label }}`
- `{% block header_filters %}` — All / Upcoming / Completed / Cancelled pill group (each link is `?filter=X` preserving other params)
- `{% block header_actions %}` — `+ New` primary CTA (links to `#`) + search icon-btn (placeholder)
- `{% block content %}` — `<div class="calendar-body" data-filter="{{ status_filter|default:'all' }}">` followed by `{% if view_mode == 'week' %}…{% else %}…{% endif %}` branch.

### Week branch
- Wraps `.week-grid` containing `.week-row`s
- Each row's 7 day-cells iterate over `day.events_enriched` and render `event-chip.short` anchors linking to `voice:visit_detail`
- Today's date numeral wrapped in `.today-circle`

### Day branch
- `.day-layout` with `.day-stream` (left) and `.day-aside` (right)
- `.day-stream` iterates `hour_buckets`, each row is `.hour-row` with `.time-label` and `.slot`
- Slot's events render as full `event-chip` (with title row)
- `.day-aside` contains `.mini-cal` (month grid) + `.day-overview` (visit count summary)
- Mini-cal day cells link to `?view=day&date={iso}`

### Status filter pills
The filter pills are anchor links with `?filter=X` preserving `view` and `date`:
```django
<a href="?view={{view_mode}}&date={{target_date|date:'Y-m-d'}}&filter=upcoming"
   class="{% if status_filter == 'upcoming' %}on{% endif %}">Upcoming</a>
```

### Agent filter
The existing agent `<select>` keeps working as a GET form. We position it inside `header_filters` block or as a small bar above the calendar body. Since `header_filters` already has the status filter pill group, the agent filter goes as a sibling pill (a `<select>` styled as `.fb-pill`).

## 7. Verification

- **Phase 1 (CSS):** `wc -l static/css/screens.css` grew by ~250; `manage.py check` passes; no template change visible yet.
- **Phase 2 (View):** Visit `/manager/calendar/?view=week` and `?view=day` — both render data without crashing. Confirm `?view=month` redirects to `?view=week`. Confirm `?filter=upcoming` etc. sets the `data-filter` attribute correctly.
- **Phase 3 (Template):** Walk both modes in a browser:
  - Week mode: 7-column grid, event chips colored by state, "This week" row highlighted, today's numeral in orange circle
  - Day mode: hour-by-hour stream, full chips with title, mini-cal sidebar with today highlighted
  - Click an event chip → lands on `/manager/visits/<id>/`
  - Click status filter pill → URL updates with `?filter=X`, non-matching chips dim to 35% opacity
  - Date pagination: Week mode = ±7 days, Day mode = ±1 day
  - Agent filter dropdown still works
- **Smoke:** `manage.py check` passes after each phase; `screens.css` returns 200.

## 8. Out of scope

- Month view (dropped)
- Drag-and-drop reschedule
- Click-to-create on empty slots
- Mini-calendar month navigation (only target date's month is shown)
- New visit creation flow (CTA points to `#`)
- Real "cancelled" state in data (uses placeholder `(visit.id % 13) == 0` rule since there's no CANCELLED enum)
- Profile dropdown menu in the top bar
- Search icon-btn behavior

## 9. Rollout & rollback

Same pattern as previous passes: stay uncommitted across phases, branch + single commit at the end on a new branch `calendar-screen` off `management-screens`. Rollback is `git revert` of the commit. No database, no service, no env changes.
