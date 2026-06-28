# Visit Calendar View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a weekly/monthly calendar page showing all visits across agents with visual day-by-day layout and agent filtering.

**Architecture:** A single Django CBV serves both week and month views via a `view` query param. A new selector (`get_visits_for_range`) fetches visits across a date range. The template uses pure Tailwind CSS grid (7 columns for days) with Tailwind card components for visit entries — no JavaScript calendar libraries needed.

**Tech Stack:** Django CBV, Tailwind CSS grid, existing Visit model

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `voice/selectors.py` | Modify | Add `get_visits_for_range()` date-range selector |
| `voice/views.py` | Modify | Add `VisitCalendarView` CBV |
| `voice/urls.py` | Modify | Add `/manager/calendar/` route |
| `voice/templates/voice/manager/visit_calendar.html` | Create | Calendar template with week/month grid |
| `voice/templates/voice/base.html` | Modify | Add "Calendar" nav link |

---

### Task 1: Add date-range selector

**Files:**
- Modify: `voice/selectors.py`

- [ ] **Step 1: Add `get_visits_for_range` to selectors.py**

Add this function after the existing `get_visits_for_date` function (around line 555):

```python
def get_visits_for_range(start_date, end_date, agent=None):
    """Get all visits within a date range, optionally filtered by agent."""
    from datetime import datetime, time as dt_time
    start_dt = timezone.make_aware(datetime.combine(start_date, dt_time.min))
    end_dt = timezone.make_aware(datetime.combine(end_date, dt_time.max))

    qs = Visit.objects.filter(
        start_time__gte=start_dt,
        start_time__lte=end_dt,
    ).select_related('agent', 'client', 'methodology')

    if agent:
        qs = qs.filter(agent=agent)

    return qs.order_by('start_time')
```

- [ ] **Step 2: Verify import**

`Visit` is already imported in selectors.py. Confirm by checking the imports at the top of the file — `Visit` should be in the `from .models import ...` line. If not, add it.

- [ ] **Step 3: Commit**

```bash
git add voice/selectors.py
git commit -m "feat: add get_visits_for_range selector for calendar view"
```

---

### Task 2: Add VisitCalendarView

**Files:**
- Modify: `voice/views.py`

- [ ] **Step 1: Add calendar helper and view**

Add this at the end of `voice/views.py`, after the `AgentMethodologyView` class:

```python
# ============================================================================
# Visit Calendar View
# ============================================================================

class VisitCalendarView(SuperuserRequiredMixin, View):
    """Weekly/monthly calendar view of all visits."""

    def get(self, request):
        from .selectors import get_visits_for_range
        from .constants import VisitStatus
        import calendar as cal_mod

        view_mode = request.GET.get('view', 'week')  # 'week' or 'month'
        agent_id = request.GET.get('agent', '')
        date_str = request.GET.get('date', '')

        # Parse target date
        if date_str:
            try:
                target_date = datetime.strptime(date_str, '%Y-%m-%d').date()
            except ValueError:
                target_date = timezone.now().date()
        else:
            target_date = timezone.now().date()

        # Resolve agent filter
        agent = None
        if agent_id:
            try:
                agent = User.objects.get(id=agent_id, is_sales_agent=True)
            except User.DoesNotExist:
                pass

        # Calculate date range
        if view_mode == 'month':
            first_day = target_date.replace(day=1)
            last_day_num = cal_mod.monthrange(target_date.year, target_date.month)[1]
            last_day = target_date.replace(day=last_day_num)
            # Extend to full weeks (Mon-Sun)
            start_date = first_day - timedelta(days=first_day.weekday())
            end_date = last_day + timedelta(days=6 - last_day.weekday())
            prev_date = (first_day - timedelta(days=1)).strftime('%Y-%m-%d')
            next_date = (last_day + timedelta(days=1)).strftime('%Y-%m-%d')
            title = target_date.strftime('%B %Y')
        else:  # week
            start_date = target_date - timedelta(days=target_date.weekday())  # Monday
            end_date = start_date + timedelta(days=6)  # Sunday
            prev_date = (start_date - timedelta(days=7)).strftime('%Y-%m-%d')
            next_date = (start_date + timedelta(days=7)).strftime('%Y-%m-%d')
            title = f"{start_date.strftime('%b %d')} - {end_date.strftime('%b %d, %Y')}"

        # Fetch visits
        visits = get_visits_for_range(start_date, end_date, agent=agent)

        # Group visits by date
        visits_by_date = {}
        for v in visits:
            day = v.start_time.date()
            visits_by_date.setdefault(day, []).append(v)

        # Build calendar grid (list of weeks, each week is list of days)
        weeks = []
        current = start_date
        while current <= end_date:
            week = []
            for _ in range(7):
                week.append({
                    'date': current,
                    'visits': visits_by_date.get(current, []),
                    'is_today': current == timezone.now().date(),
                    'is_current_month': current.month == target_date.month,
                })
                current += timedelta(days=1)
            weeks.append(week)

        agents = User.objects.filter(is_sales_agent=True).order_by('username')

        context = {
            'weeks': weeks,
            'view_mode': view_mode,
            'target_date': target_date,
            'title': title,
            'prev_date': prev_date,
            'next_date': next_date,
            'agents': agents,
            'agent_filter': agent_id,
            'today': timezone.now().date(),
        }
        return render(request, 'voice/manager/visit_calendar.html', context)
```

- [ ] **Step 2: Commit**

```bash
git add voice/views.py
git commit -m "feat: add VisitCalendarView with week/month modes"
```

---

### Task 3: Add URL pattern

**Files:**
- Modify: `voice/urls.py`

- [ ] **Step 1: Add calendar URL**

Add this line after the `visit_detail` path (around line 38):

```python
    path('manager/calendar/', views.VisitCalendarView.as_view(), name='visit_calendar'),
```

- [ ] **Step 2: Commit**

```bash
git add voice/urls.py
git commit -m "feat: add /manager/calendar/ URL route"
```

---

### Task 4: Create calendar template

**Files:**
- Create: `voice/templates/voice/manager/visit_calendar.html`

- [ ] **Step 1: Create the template**

```html
{% extends 'voice/base.html' %}

{% block title %}Calendar - MES Voice{% endblock %}

{% block content %}
<div class="container mx-auto px-4 py-8">
    <!-- Header -->
    <div class="flex flex-wrap items-center justify-between mb-6 gap-4">
        <div>
            <h1 class="text-4xl font-bold">{{ title }}</h1>
            <p class="text-base-content/70">Visit calendar</p>
        </div>
        <div class="flex items-center gap-2">
            <!-- View toggle -->
            <div class="btn-group">
                <a href="?view=week&date={{ target_date|date:'Y-m-d' }}&agent={{ agent_filter }}"
                   class="btn btn-sm {% if view_mode == 'week' %}btn-active{% endif %}">Week</a>
                <a href="?view=month&date={{ target_date|date:'Y-m-d' }}&agent={{ agent_filter }}"
                   class="btn btn-sm {% if view_mode == 'month' %}btn-active{% endif %}">Month</a>
            </div>
            <!-- Navigation -->
            <a href="?view={{ view_mode }}&date={{ prev_date }}&agent={{ agent_filter }}" class="btn btn-sm btn-outline">&larr;</a>
            <a href="?view={{ view_mode }}&date={{ today|date:'Y-m-d' }}&agent={{ agent_filter }}" class="btn btn-sm btn-ghost">Today</a>
            <a href="?view={{ view_mode }}&date={{ next_date }}&agent={{ agent_filter }}" class="btn btn-sm btn-outline">&rarr;</a>
        </div>
    </div>

    <!-- Agent filter -->
    <div class="card bg-base-100 shadow mb-4">
        <div class="card-body py-3">
            <form method="get" class="flex items-center gap-3">
                <input type="hidden" name="view" value="{{ view_mode }}">
                <input type="hidden" name="date" value="{{ target_date|date:'Y-m-d' }}">
                <label class="label-text font-semibold">Agent:</label>
                <select name="agent" class="select select-bordered select-sm" onchange="this.form.submit()">
                    <option value="">All Agents</option>
                    {% for a in agents %}
                    <option value="{{ a.id }}" {% if agent_filter == a.id|stringformat:"d" %}selected{% endif %}>
                        {{ a.get_full_name|default:a.username }}
                    </option>
                    {% endfor %}
                </select>
            </form>
        </div>
    </div>

    <!-- Calendar grid -->
    <div class="card bg-base-100 shadow-xl">
        <div class="card-body p-2 md:p-4">
            <!-- Day headers -->
            <div class="grid grid-cols-7 gap-1 mb-1">
                {% for day_name in "Mon,Tue,Wed,Thu,Fri,Sat,Sun"|make_list %}
                {% endfor %}
                <div class="text-center text-sm font-semibold text-base-content/70 py-1">Mon</div>
                <div class="text-center text-sm font-semibold text-base-content/70 py-1">Tue</div>
                <div class="text-center text-sm font-semibold text-base-content/70 py-1">Wed</div>
                <div class="text-center text-sm font-semibold text-base-content/70 py-1">Thu</div>
                <div class="text-center text-sm font-semibold text-base-content/70 py-1">Fri</div>
                <div class="text-center text-sm font-semibold text-base-content/70 py-1">Sat</div>
                <div class="text-center text-sm font-semibold text-base-content/70 py-1">Sun</div>
            </div>

            <!-- Weeks -->
            {% for week in weeks %}
            <div class="grid grid-cols-7 gap-1">
                {% for day in week %}
                <div class="border border-base-300 rounded-lg p-1 {% if view_mode == 'week' %}min-h-32{% else %}min-h-24{% endif %} {% if day.is_today %}bg-primary/5 border-primary{% endif %} {% if not day.is_current_month %}opacity-40{% endif %}">
                    <!-- Date number -->
                    <div class="text-right text-xs {% if day.is_today %}font-bold text-primary{% else %}text-base-content/50{% endif %} mb-1">
                        {{ day.date.day }}
                    </div>
                    <!-- Visits -->
                    {% for visit in day.visits %}
                    <a href="{% url 'voice:visit_detail' visit.id %}"
                       class="block mb-1 rounded px-1 py-0.5 text-xs truncate hover:opacity-80
                              {% if visit.status == 'COMPLETE' %}bg-success/20 text-success
                              {% elif visit.status == 'POST_CALL_DONE' %}bg-info/20 text-info
                              {% elif visit.status == 'PRE_CALL_DONE' %}bg-primary/20 text-primary
                              {% else %}bg-base-300 text-base-content{% endif %}">
                        <span class="font-semibold">{{ visit.start_time|date:"H:i" }}</span>
                        {{ visit.title|truncatewords:3 }}
                        {% if not agent_filter %}
                        <span class="opacity-60">- {{ visit.agent.username }}</span>
                        {% endif %}
                    </a>
                    {% endfor %}
                </div>
                {% endfor %}
            </div>
            {% endfor %}
        </div>
    </div>

    <!-- Legend -->
    <div class="flex flex-wrap gap-4 mt-4 text-xs">
        <div class="flex items-center gap-1"><div class="w-3 h-3 rounded bg-base-300"></div> Planned</div>
        <div class="flex items-center gap-1"><div class="w-3 h-3 rounded bg-primary/30"></div> Pre-Call Done</div>
        <div class="flex items-center gap-1"><div class="w-3 h-3 rounded bg-info/30"></div> Post-Call Done</div>
        <div class="flex items-center gap-1"><div class="w-3 h-3 rounded bg-success/30"></div> Complete</div>
    </div>
</div>
{% endblock %}
```

- [ ] **Step 2: Commit**

```bash
git add voice/templates/voice/manager/visit_calendar.html
git commit -m "feat: add visit calendar template with week/month grid"
```

---

### Task 5: Add nav link

**Files:**
- Modify: `voice/templates/voice/base.html`

- [ ] **Step 1: Add Calendar link to nav**

In `base.html`, find the superuser nav section and add a Calendar link. Change:

```html
<li><a href="{% url 'voice:visit_list' %}">Visits</a></li>
```

to:

```html
<li><a href="{% url 'voice:visit_list' %}">Visits</a></li>
<li><a href="{% url 'voice:visit_calendar' %}">Calendar</a></li>
```

- [ ] **Step 2: Commit**

```bash
git add voice/templates/voice/base.html
git commit -m "feat: add Calendar link to manager navigation"
```

---

### Task 6: Verify everything works

- [ ] **Step 1: Run Django system check**

```bash
python manage.py check
```

Expected: No errors (only the pre-existing staticfiles warning).

- [ ] **Step 2: Test view rendering**

```bash
python -c "
import os, django
os.environ['DJANGO_SETTINGS_MODULE'] = 'proj_mes_voice.settings'
django.setup()
from django.test import RequestFactory
from voice.views import VisitCalendarView
from voice.models import User
admin = User.objects.get(username='admin')
factory = RequestFactory()

# Week view
req = factory.get('/manager/calendar/?view=week')
req.user = admin
resp = VisitCalendarView.as_view()(req)
print(f'Week view: {resp.status_code}')

# Month view
req = factory.get('/manager/calendar/?view=month')
req.user = admin
resp = VisitCalendarView.as_view()(req)
print(f'Month view: {resp.status_code}')

# With agent filter
req = factory.get('/manager/calendar/?view=week&agent=2')
req.user = admin
resp = VisitCalendarView.as_view()(req)
print(f'Filtered view: {resp.status_code}')
"
```

Expected: All three return `200`.

- [ ] **Step 3: Test URL resolution**

```bash
python -c "
import os, django
os.environ['DJANGO_SETTINGS_MODULE'] = 'proj_mes_voice.settings'
django.setup()
from django.urls import reverse
print(reverse('voice:visit_calendar'))
"
```

Expected: `/manager/calendar/`

- [ ] **Step 4: Test selector**

```bash
python -c "
import os, django
os.environ['DJANGO_SETTINGS_MODULE'] = 'proj_mes_voice.settings'
django.setup()
from voice.selectors import get_visits_for_range
from django.utils import timezone
from datetime import timedelta
today = timezone.now().date()
visits = get_visits_for_range(today, today + timedelta(days=6))
print(f'Visits this week: {visits.count()}')
"
```

Expected: Shows count of visits (6 with synthetic data).

- [ ] **Step 5: Open in browser and verify**

Navigate to `http://localhost:8003/manager/calendar/` and confirm:
- Week view shows 7-day grid with visits
- Month view shows full month grid
- Agent dropdown filters visits
- Arrow buttons navigate forward/backward
- Today button jumps to current week/month
- Visit entries are clickable (link to detail)
- Status colors match legend

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "feat: complete visit calendar view with week/month modes and agent filtering"
```
