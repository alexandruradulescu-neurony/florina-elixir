# Calendar Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the existing Week/Month calendar with a redesigned Week + Day calendar matching the Claude Design package, including state-colored event chips, mini-calendar sidebar on Day mode, and CSS-only status filter dimming.

**Architecture:** Four sequential tasks on top of branch `management-screens`. Task 1 appends ~250 lines of calendar CSS to `screens.css`. Task 2 appends a `calendar_extras` helper to `voice/placeholders.py`. Task 3 extends `VisitCalendarView` to support `view=day` (and redirect `view=month` to `view=week`). Task 4 rewrites `visit_calendar.html` as a single template with mode-branching. Tasks 5–6 verify and commit on a new branch.

**Tech Stack:** Django 4.2 templates, hand-rolled CSS via existing design tokens, no JS.

**Source spec:** [docs/superpowers/specs/2026-05-26-calendar-screen-design.md](../specs/2026-05-26-calendar-screen-design.md)

**Builds on:** branch `management-screens` at commit `a23394e` (which is the spec commit on top of all prior implementation).

---

## Conventions

- Working directory is the repo root: `/Users/alex/Code/proj-salesassistant`.
- **DO NOT commit per task.** Per the established pattern, work stays uncommitted across all phases; final commit happens in Task 6.
- After every file change, run `python manage.py check` to confirm no template-syntax errors.

---

## Task 1: Append calendar CSS to `static/css/screens.css`

**Files:**
- Modify: `static/css/screens.css` (append)

**Step 1: Append this exact CSS block to the END of `static/css/screens.css`**

```css

/* ============================================================================
   Calendar — top bar / filter bar tweaks
   ============================================================================ */
.cal-nav {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.cal-nav-label {
  display: inline-flex;
  align-items: center;
  padding: 0 12px;
  height: 36px;
  border-radius: var(--radius-pill);
  background: var(--bg-surface);
  border: 1px solid var(--border-default);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 13px;
  color: var(--fg-strong);
}

/* ============================================================================
   Event chip — used in both Week and Day modes
   ============================================================================ */
.event-chip {
  display: block;
  border-radius: 4px;
  padding: 5px 6px;
  box-shadow: var(--shadow-tile);
  font-family: var(--font-tile);
  text-decoration: none;
  cursor: pointer;
  transition: opacity 120ms ease-out;
}
.event-chip .top {
  display: flex;
  align-items: center;
  gap: 4px;
  font-family: var(--font-tile);
  font-weight: 700;
  font-size: 11px;
  line-height: 1;
}
.event-chip .top .time { flex: 1; }
.event-chip .top .state-icon { width: 10px; height: 10px; }
.event-chip .title {
  display: block;
  margin-top: 4px;
  font-family: var(--font-tile);
  font-weight: 700;
  font-size: 13px;
  line-height: 1.2;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.event-chip.short .title { display: none; }
.event-chip-upcoming  { background: var(--cyan-500); color: #fff; }
.event-chip-completed { background: var(--green-100); color: var(--green-700); }
.event-chip-cancelled { background: var(--rose-100);  color: var(--rose-700); }
.event-chip-replanned { background: var(--amber-100); color: var(--zinc-950); }

/* ============================================================================
   Week grid
   ============================================================================ */
.week-grid {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.week-row {
  display: grid;
  grid-template-columns: repeat(7, 1fr);
  gap: 6px;
  position: relative;
}
.week-row.this-week .day-cell {
  background: var(--cyan-50);
}
.this-week-badge {
  position: absolute;
  top: -10px;
  left: 8px;
  height: 18px;
  padding: 0 8px;
  background: var(--zinc-950);
  color: #fff;
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 9px;
  letter-spacing: 0.12em;
  display: inline-flex;
  align-items: center;
  z-index: 1;
}
.day-cell {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: 8px;
  padding: 8px;
  min-height: 120px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.day-cell .dow-line {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 4px;
}
.day-cell .dow-line .dow {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
}
.day-cell .dow-line .dnum {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 16px;
  line-height: 1;
  color: var(--fg-strong);
}
.day-cell .dow-line .dnum.today-circle {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  background: var(--orange-500);
  color: #fff;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
}
.day-cell .events {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.day-cell.empty .no-events {
  display: block;
  text-align: center;
  padding-top: 30px;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 12px;
  color: var(--fg-muted);
}

/* ============================================================================
   Day mode — hour stream + aside
   ============================================================================ */
.day-layout {
  display: grid;
  grid-template-columns: 1fr 320px;
  gap: 16px;
}
.day-stream {
  display: flex;
  flex-direction: column;
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  overflow: hidden;
}
.hour-row {
  display: grid;
  grid-template-columns: 60px 1fr;
  min-height: 56px;
  border-top: 1px solid var(--border-hairline);
}
.hour-row:first-child { border-top: none; }
.hour-row .time-label {
  text-align: right;
  padding: 8px 8px 0 0;
  font-family: var(--font-tile);
  font-weight: 700;
  font-size: 11px;
  color: var(--fg-muted);
  font-feature-settings: 'tnum';
}
.hour-row .slot {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 6px 8px;
}

/* ─────────── Day aside ─────────── */
.day-aside {
  display: flex;
  flex-direction: column;
  gap: 16px;
  position: sticky;
  top: 24px;
  align-self: start;
}
.mini-cal {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: 12px;
  padding: 16px;
}
.mini-cal-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 12px;
}
.mini-cal-head .label {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 14px;
  color: var(--fg-strong);
}
.mini-cal-head .nav-btn {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  background: transparent;
  border: 1px solid var(--border-default);
  color: var(--fg-strong);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  text-decoration: none;
}
.mini-cal-grid {
  display: grid;
  grid-template-columns: repeat(7, 1fr);
  gap: 2px;
}
.mini-cal-grid .dow-h {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 9px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
  text-align: center;
  padding-bottom: 6px;
}
.mini-cal-day {
  width: 32px;
  height: 32px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  margin: 0 auto;
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
  color: var(--fg-strong);
  text-decoration: none;
}
.mini-cal-day:hover {
  background: var(--zinc-100);
}
.mini-cal-day.dim { color: var(--fg-faint); }
.mini-cal-day.today { background: var(--cyan-200); }
.mini-cal-day.selected { background: var(--cyan-500); color: #fff; }
.day-overview {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  padding: 20px;
}
.day-overview h3 {
  margin: 0 0 12px;
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 12px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
}
.day-overview p {
  margin: 0;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg);
}

/* ============================================================================
   Filter dimming (CSS-only, via data-filter attribute on .calendar-body)
   ============================================================================ */
.calendar-body[data-filter="upcoming"]  .event-chip:not(.event-chip-upcoming)  { opacity: 0.35; }
.calendar-body[data-filter="completed"] .event-chip:not(.event-chip-completed) { opacity: 0.35; }
.calendar-body[data-filter="cancelled"] .event-chip:not(.event-chip-cancelled):not(.event-chip-replanned) { opacity: 0.35; }
```

**Step 2: Verify**

```bash
wc -l static/css/screens.css
python manage.py check
grep -c "^\.event-chip\|^\.week-grid\|^\.day-layout\|^\.mini-cal" static/css/screens.css
```

Expected: ~1870 lines now (was ~1623); check passes; grep returns >= 4 (new sections present).

DO NOT commit.

---

## Task 2: Append `calendar_extras` to `voice/placeholders.py`

**Files:**
- Modify: `voice/placeholders.py` (append)

**Step 1: Append this exact Python code to the END of `voice/placeholders.py`**

```python


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
    from datetime import date, timedelta
    from django.utils import timezone

    today = timezone.now().date()
    # Find the first day of the month, then the Monday on/before it
    first_of_month = target_date.replace(day=1)
    # Python weekday(): Monday=0..Sunday=6
    offset = first_of_month.weekday()
    grid_start = first_of_month - timedelta(days=offset)

    cells = []
    for i in range(42):  # 6 weeks × 7 days
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

    # Common header labels
    context["month_label"] = target_date.strftime("%B %Y")
    if view_mode == "day":
        from django.utils import timezone
        today = timezone.now().date()
        context["nav_label"] = "Today" if target_date == today else target_date.strftime("%A")
    else:
        context["nav_label"] = "This week"

    # Status filter (drives CSS dimming)
    context.setdefault("status_filter", "all")

    if view_mode == "day":
        visits_for_day = context.get("visits_for_day") or []
        context["hour_buckets"] = _build_hour_buckets(visits_for_day)
        context["month_grid"] = _build_mini_cal_month(target_date)
        context["day_visit_count"] = len(visits_for_day)
    else:
        # Week mode: enrich each day's visits in the existing weeks structure.
        from django.utils import timezone
        today = timezone.now().date()
        enriched_weeks = []
        for week in context.get("weeks", []):
            # The existing view stores week as a list of day dicts:
            # [{date, visits, is_today, is_current_month}, ...]
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
```

**Step 2: Verify**

```bash
python -c "from voice import placeholders; print('calendar_extras' in dir(placeholders))"
python manage.py check
```

Expected: prints `True`; check passes.

DO NOT commit.

---

## Task 3: Extend `VisitCalendarView` for Day mode + filter param

**Files:**
- Modify: `voice/views.py`

**Step 1: Locate the view**

```bash
grep -n "class VisitCalendarView" voice/views.py
```

The view is around line 1643. Read the existing get method to understand the current flow:
- Reads `view`, `date`, `agent` from GET params
- Builds `target_date`, `prev_date`, `next_date`, `weeks`, `view_mode`, etc.
- Calls `get_visits_for_range(start, end, agent)` to fetch visits
- Returns `render(request, 'voice/manager/visit_calendar.html', context)`

**Step 2: Modify the view's get method**

The exact edits depend on the current implementation. Read the view body first, then apply the following changes (preserve existing logic for agent filter, agent_color_map, etc.):

1. **Change valid view modes:**

Find the line(s) that validate `view_mode`. The current logic likely has:

```python
view_mode = request.GET.get('view', 'week')
if view_mode not in ('week', 'month'):
    view_mode = 'week'
```

Replace with:

```python
view_mode = request.GET.get('view', 'week')
if view_mode == 'month':
    # Old bookmark — redirect to week
    from django.shortcuts import redirect
    return redirect(f"{request.path}?view=week&date={target_date}")
if view_mode not in ('week', 'day'):
    view_mode = 'week'
```

(If `target_date` is built after this check in the current code, move the `view_mode == 'month'` redirect to AFTER `target_date` is computed.)

2. **Add Day-mode branch that fetches visits for a single day:**

After the existing week-mode logic that builds `weeks`, wrap it in an `if view_mode == 'week'` and add an `elif view_mode == 'day'` branch:

```python
if view_mode == 'week':
    # existing week-building logic — DO NOT change
    weeks = [...]
    context['weeks'] = weeks
    prev_date = target_date - timedelta(days=7)
    next_date = target_date + timedelta(days=7)
elif view_mode == 'day':
    visits_for_day = list(get_visits_for_range(target_date, target_date, agent=agent_filter_obj))
    context['visits_for_day'] = visits_for_day
    prev_date = target_date - timedelta(days=1)
    next_date = target_date + timedelta(days=1)
```

Update `context['prev_date']` and `context['next_date']` from these computed values.

3. **Pass `status_filter` to context:**

After parsing GET params, add:

```python
status_filter = request.GET.get('filter', 'all')
if status_filter not in ('all', 'upcoming', 'completed', 'cancelled'):
    status_filter = 'all'
context['status_filter'] = status_filter
```

4. **Call placeholder helper at the end:**

Right before `return render(...)`, add:

```python
        placeholders.calendar_extras(context)
```

5. **Verify imports:**

Make sure `from datetime import timedelta` and `from voice import placeholders` are present at the top of `voice/views.py` (they should be — both used by other code).

**Step 3: Verify**

```bash
python manage.py check
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8003/manager/calendar/?view=week"
curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8003/manager/calendar/?view=day"
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" "http://localhost:8003/manager/calendar/?view=month"
```

Expected:
- check passes
- `view=week` and `view=day` return 302 (auth redirect, since we're not authenticated via curl)
- `view=month` returns 302 with a redirect — without auth this redirects to login; with auth it would redirect to `?view=week`

DO NOT commit.

---

## Task 4: Rewrite `voice/templates/voice/manager/visit_calendar.html`

**Files:**
- Modify: `voice/templates/voice/manager/visit_calendar.html` (full rewrite)

**Step 1: Replace the entire file**

```django
{% extends "voice/base.html" %}
{% load static %}

{% block title %}Calendar — Sales Assistant{% endblock %}

{% block header_utility %}
<div class="toggle">
    <a href="?view=week&date={{ target_date|date:'Y-m-d' }}" class="{% if view_mode == 'week' %}on{% endif %}">Week</a>
    <a href="?view=day&date={{ target_date|date:'Y-m-d' }}" class="{% if view_mode == 'day' %}on{% endif %}">Day</a>
</div>
<div class="cal-nav">
    <a href="?view={{ view_mode }}&date={{ prev_date|date:'Y-m-d' }}" class="icon-btn" aria-label="Previous"><span class="ic ic-angle-left"></span></a>
    <span class="cal-nav-label">{{ nav_label }}</span>
    <a href="?view={{ view_mode }}&date={{ next_date|date:'Y-m-d' }}" class="icon-btn" aria-label="Next"><span class="ic ic-angle-right"></span></a>
</div>
{% endblock %}

{% block display_title %}{{ month_label }}{% endblock %}

{% block header_filters %}
<div class="filters">
    <a href="?view={{ view_mode }}&date={{ target_date|date:'Y-m-d' }}&filter=all" class="{% if status_filter == 'all' %}on{% endif %}">All</a>
    <a href="?view={{ view_mode }}&date={{ target_date|date:'Y-m-d' }}&filter=upcoming" class="{% if status_filter == 'upcoming' %}on{% endif %}">Upcoming</a>
    <a href="?view={{ view_mode }}&date={{ target_date|date:'Y-m-d' }}&filter=completed" class="{% if status_filter == 'completed' %}on{% endif %}">Completed</a>
    <a href="?view={{ view_mode }}&date={{ target_date|date:'Y-m-d' }}&filter=cancelled" class="{% if status_filter == 'cancelled' %}on{% endif %}">Cancelled</a>
</div>
{% endblock %}

{% block header_actions %}
<form method="get" style="display:inline-flex;align-items:center;">
    <input type="hidden" name="view" value="{{ view_mode }}">
    <input type="hidden" name="date" value="{{ target_date|date:'Y-m-d' }}">
    <input type="hidden" name="filter" value="{{ status_filter }}">
    <select name="agent" onchange="this.form.submit()" class="fb-pill" style="height:36px;padding:0 14px;border:1px solid var(--border-default);border-radius:var(--radius-pill);background:var(--bg-surface);font-family:var(--font-ui);font-weight:700;font-size:13px;color:var(--fg-strong);">
        <option value="">All agents</option>
        {% for a in agents %}<option value="{{ a.id }}" {% if agent_filter == a.id|stringformat:'s' %}selected{% endif %}>{{ a.get_full_name|default:a.username }}</option>{% endfor %}
    </select>
</form>
<a href="#" class="btn btn-primary"><span class="ic ic-plus ic-14"></span> New</a>
<button class="icon-btn" type="button" aria-label="Search"><span class="ic ic-search ic-16"></span></button>
{% endblock %}

{% block content %}

<div class="calendar-body" data-filter="{{ status_filter|default:'all' }}">

{% if view_mode == 'week' %}

<div class="week-grid">
    {% for week in weeks_enriched %}
    <div class="week-row{% if week.is_current_week %} this-week{% endif %}">
        {% if week.is_current_week %}<span class="this-week-badge">This week</span>{% endif %}
        {% for day in week.days %}
        <div class="day-cell{% if not day.has_events %} empty{% endif %}">
            <div class="dow-line">
                <span class="dow">{{ day.date|date:"D" }}</span>
                <span class="dnum{% if day.is_today %} today-circle{% endif %}">{{ day.date|date:"j" }}</span>
            </div>
            <div class="events">
                {% for ev in day.events_enriched %}
                <a href="{% url 'voice:visit_detail' visit_id=ev.visit.id %}" class="event-chip event-chip-{{ ev.state }} short">
                    <div class="top">
                        <span class="time">{{ ev.time_range }}</span>
                        {% if ev.state == 'completed' %}<span class="state-icon ic ic-check"></span>
                        {% elif ev.state == 'cancelled' %}<span class="state-icon ic ic-ban"></span>{% endif %}
                    </div>
                </a>
                {% empty %}
                <span class="no-events">No events</span>
                {% endfor %}
            </div>
        </div>
        {% endfor %}
    </div>
    {% endfor %}
</div>

{% else %}

<div class="day-layout">
    <div class="day-stream">
        {% for bucket in hour_buckets %}
        <div class="hour-row">
            <span class="time-label">{{ bucket.hour_label }}</span>
            <div class="slot">
                {% for ev in bucket.events %}
                <a href="{% url 'voice:visit_detail' visit_id=ev.visit.id %}" class="event-chip event-chip-{{ ev.state }}">
                    <div class="top">
                        <span class="time">{{ ev.time_range }}</span>
                        {% if ev.state == 'completed' %}<span class="state-icon ic ic-check"></span>
                        {% elif ev.state == 'cancelled' %}<span class="state-icon ic ic-ban"></span>{% endif %}
                    </div>
                    <div class="title">{{ ev.title }}</div>
                </a>
                {% endfor %}
            </div>
        </div>
        {% endfor %}
    </div>

    <aside class="day-aside">
        <div class="mini-cal">
            <div class="mini-cal-head">
                <a href="#" class="nav-btn" aria-label="Previous month">←</a>
                <span class="label">{{ month_label }}</span>
                <a href="#" class="nav-btn" aria-label="Next month">→</a>
            </div>
            <div class="mini-cal-grid">
                <span class="dow-h">Mon</span><span class="dow-h">Tue</span><span class="dow-h">Wed</span><span class="dow-h">Thu</span><span class="dow-h">Fri</span><span class="dow-h">Sat</span><span class="dow-h">Sun</span>
                {% for day in month_grid %}
                <a href="?view=day&date={{ day.iso }}&filter={{ status_filter }}" class="mini-cal-day{% if not day.in_month %} dim{% endif %}{% if day.is_today %} today{% endif %}{% if day.is_selected %} selected{% endif %}">{{ day.day_num }}</a>
                {% endfor %}
            </div>
        </div>
        <div class="day-overview">
            <h3>Day overview</h3>
            <p>{{ day_visit_count }} visit{{ day_visit_count|pluralize }} on {{ target_date|date:"l, F j" }}</p>
        </div>
    </aside>
</div>

{% endif %}

</div>

{% endblock %}
```

**Step 2: Verify**

```bash
python manage.py check
```

Expected: passes.

DO NOT commit.

---

## Task 5: Smoke verification

**Files:** none modified.

**Step 1: Start dev server if not running**

```bash
python manage.py runserver 0.0.0.0:8003
```

**Step 2: Verify static + Django**

```bash
python manage.py check
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8003/static/css/screens.css
```

Expected: check passes; curl returns 200.

**Step 3: Browser walkthrough (logged in as superuser)**

| URL | Expected |
|---|---|
| `/manager/calendar/` | Week mode (default), 7-col grid, this-week row highlighted cyan-50, today's date numeral in orange circle |
| `/manager/calendar/?view=week&date=2026-04-01` | Week mode for April 1 week — chips render with state colors |
| `/manager/calendar/?view=day&date=2026-05-26` | Day mode for May 26: hour-by-hour stream + mini-calendar sidebar |
| `/manager/calendar/?view=month` | Redirects to `?view=week` |
| `/manager/calendar/?filter=upcoming` | URL updates; non-upcoming chips dim to 35% opacity |
| `/manager/calendar/?filter=completed` | Only completed chips remain at full opacity |
| Click an event chip | Navigates to `/manager/visits/<id>/` |
| Click a mini-cal day | Switches to Day mode for that date |
| Agent dropdown | Filters visits by agent |

**Step 4: Stop dev server**

Ctrl+C.

No commit yet — Task 6 handles that.

---

## Task 6: Branch + commit

**Files:** none staged yet.

**Step 1: Inspect what changed**

```bash
git status --short
```

**Step 2: Branch off `management-screens`**

```bash
git rev-parse --abbrev-ref HEAD
```

If currently on `management-screens`:

```bash
git checkout -b calendar-screen
```

**Step 3: Stage only this pass's files**

```bash
git add static/css/screens.css \
        voice/placeholders.py \
        voice/views.py \
        voice/templates/voice/manager/visit_calendar.html \
        docs/superpowers/plans/2026-05-26-calendar-screen.md
```

Verify with `git status --short`.

**Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
Calendar screen: Week + Day views per Claude Design

Implements docs/superpowers/plans/2026-05-26-calendar-screen.md.

Phase 1 — Calendar CSS in screens.css (~250 lines):
- .event-chip with state variants (upcoming/completed/cancelled/replanned)
- .event-chip.short for Week mode (hides title row)
- .week-grid / .week-row / .day-cell with this-week highlight and
  orange today-circle
- .day-layout / .day-stream / .hour-row for Day mode
- .day-aside / .mini-cal / .mini-cal-grid for the sidebar mini-calendar
- .calendar-body[data-filter] CSS-only dimming for non-matching chips

Phase 2 — calendar_extras in voice/placeholders.py:
- _visit_state: maps VisitStatus to design states + placeholder rule
  for cancelled/replanned (no CANCELLED enum yet)
- _enrich_event: per-event dict with state/time_range/title
- _build_hour_buckets: 09:00-18:00 default, extended for outlier visits
- _build_mini_cal_month: 6x7 month grid for Day-mode sidebar
- calendar_extras: branches on view_mode (week|day), builds month_label,
  nav_label, status_filter, hour_buckets, month_grid, weeks_enriched

Phase 3 — VisitCalendarView:
- Accept view=day; redirect view=month to view=week
- Day mode: visits_for_day from get_visits_for_range, ±1 day pagination
- Week mode unchanged: ±7 day pagination
- New status_filter GET param ('all'|'upcoming'|'completed'|'cancelled')
- Calls placeholders.calendar_extras(context) before render

Phase 4 — visit_calendar.html (full rewrite, single template):
- Top bar: view toggle (Week|Day) + prev/next nav
- Page row: month label + status filter pills + agent dropdown + New CTA
- Week branch: .week-grid with .week-row x N, each with 7 .day-cells
- Day branch: .day-layout with hour stream + sticky mini-cal aside
- Event chips link to voice:visit_detail
- Mini-cal days link to ?view=day&date=<iso>

Out of scope (named in spec): month view, drag/drop, click-to-create,
real cancelled state, mini-cal month nav (placeholder #), new visit
creation, profile dropdown menu.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)" && git log --oneline -5
```

**Step 5: Confirm**

Expected: one new commit at the top of branch `calendar-screen`.

---

## Out of scope (named so we don't drift)

- Month view (dropped from this pass)
- Drag-and-drop reschedule
- Click-to-create on empty slots
- Mini-calendar month navigation (only target date's month is shown)
- New visit creation flow (CTA points to `#`)
- Real "cancelled" state (uses placeholder `(visit.id % 13) == 0` rule)
- Profile dropdown, search modal, notifications popover

## Rollback

`git revert` of the commit from Task 6. No database, no service, no env changes.
