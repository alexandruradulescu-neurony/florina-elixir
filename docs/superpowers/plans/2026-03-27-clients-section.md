# Clients Section Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Clients list page and Client detail page so the sales manager can browse CRM-synced clients, view visit history, and see AI summaries.

**Architecture:** Two new views (ClientListView, ClientDetailView) following the existing CBV pattern with SuperuserRequiredMixin. New selectors for enriched client data. Two new templates following the modernized design system (teal accent, rounded-xl, border-slate-200). Sidebar nav gets a "Clients" entry under the "Manage" group.

**Tech Stack:** Django 4.2, Tailwind CSS + DaisyUI via CDN, existing Client model + selectors

---

### File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `voice/selectors.py` | Modify | Add `get_clients_with_stats()` and `get_client_detail()` selectors |
| `voice/views.py` | Modify | Add `ClientListView` and `ClientDetailView` classes |
| `voice/urls.py` | Modify | Add 2 URL patterns for client list + detail |
| `voice/templates/voice/base.html` | Modify | Add "Clients" nav item to sidebar under Manage |
| `voice/templates/voice/manager/client_list.html` | Create | Client list page template |
| `voice/templates/voice/manager/client_detail.html` | Create | Client detail page template |

---

### Task 1: Add Client Selectors

**Files:**
- Modify: `voice/selectors.py` (append after existing client selectors, ~line 535)

- [ ] **Step 1: Add `get_clients_with_stats` selector**

Append to `voice/selectors.py` after the existing `get_stale_clients` function:

```python
def get_clients_with_stats():
    """
    Get all clients enriched with visit count, last visit date, and sync status.
    Returns list of dicts for template consumption.
    """
    from .models import User
    clients = Client.objects.all().order_by('name')
    now = timezone.now()
    result = []

    for client in clients:
        visits = Visit.objects.filter(client=client)
        total_visits = visits.count()
        last_visit = visits.order_by('-start_time').first()
        agents = User.objects.filter(
            is_sales_agent=True,
            id__in=visits.values_list('agent_id', flat=True).distinct()
        )

        is_stale = (
            client.last_synced_at is None
            or (now - client.last_synced_at).total_seconds() > 86400
        )

        result.append({
            'client': client,
            'total_visits': total_visits,
            'last_visit': last_visit,
            'agent_count': agents.count(),
            'has_summary': bool(client.ai_summary),
            'has_contacts': bool(client.contacts and len(client.contacts) > 0),
            'is_stale': is_stale,
        })

    return result


def get_client_detail(client_id):
    """
    Get a single client with related visits, calls, and agents.
    Returns dict with enriched data or None if not found.
    """
    from .models import User
    try:
        client = Client.objects.get(id=client_id)
    except Client.DoesNotExist:
        return None

    visits = Visit.objects.filter(
        client=client
    ).select_related('agent', 'methodology').order_by('-start_time')

    agents = User.objects.filter(
        is_sales_agent=True,
        id__in=visits.values_list('agent_id', flat=True).distinct()
    ).select_related('default_methodology')

    total_visits = visits.count()
    completed_visits = visits.filter(status=VisitStatus.COMPLETE).count()

    # Recent calls via visits
    from .models import CallAttempt
    recent_calls = CallAttempt.objects.filter(
        visit__client=client
    ).select_related('visit', 'visit__agent').order_by('-created_at')[:10]

    return {
        'client': client,
        'visits': visits[:20],
        'agents': agents,
        'recent_calls': recent_calls,
        'total_visits': total_visits,
        'completed_visits': completed_visits,
        'completion_rate': round(completed_visits / total_visits * 100) if total_visits else 0,
    }
```

- [ ] **Step 2: Verify no syntax errors**

Run: `python manage.py check`
Expected: No errors (just the staticfiles warning)

- [ ] **Step 3: Commit**

```bash
git add voice/selectors.py
git commit -m "feat: add client list and detail selectors"
```

---

### Task 2: Add Client Views

**Files:**
- Modify: `voice/views.py` (add two new view classes)

- [ ] **Step 1: Add import for new selectors**

In `voice/views.py`, update the selectors import block (~line 21) to include:

```python
from .selectors import (
    # ... existing imports ...
    get_clients_with_stats,
    get_client_detail,
)
```

- [ ] **Step 2: Add ClientListView class**

Add after the existing `AgentMethodologyView` class (before the Sales Agent dashboard views):

```python
class ClientListView(SuperuserRequiredMixin, View):
    """Browse all CRM-synced clients."""

    def get(self, request):
        search = request.GET.get('q', '').strip()
        clients = get_clients_with_stats()

        if search:
            clients = [
                c for c in clients
                if search.lower() in c['client'].name.lower()
                or (c['client'].industry and search.lower() in c['client'].industry.lower())
                or (c['client'].domain and search.lower() in c['client'].domain.lower())
            ]

        total_count = Client.objects.count()
        with_summary = Client.objects.filter(ai_summary__isnull=False).exclude(ai_summary='').count()

        context = {
            'clients': clients,
            'search': search,
            'total_count': total_count,
            'with_summary': with_summary,
        }
        return render(request, 'voice/manager/client_list.html', context)
```

- [ ] **Step 3: Add ClientDetailView class**

Add directly after `ClientListView`:

```python
class ClientDetailView(SuperuserRequiredMixin, View):
    """View a single client's full profile, visits, and call history."""

    def get(self, request, client_id):
        data = get_client_detail(client_id)
        if data is None:
            messages.error(request, 'Client not found.')
            return redirect('voice:client_list')

        context = data
        return render(request, 'voice/manager/client_detail.html', context)
```

- [ ] **Step 4: Verify no syntax errors**

Run: `python manage.py check`
Expected: No errors

- [ ] **Step 5: Commit**

```bash
git add voice/views.py
git commit -m "feat: add ClientListView and ClientDetailView"
```

---

### Task 3: Add URL Patterns

**Files:**
- Modify: `voice/urls.py`

- [ ] **Step 1: Add client URL patterns**

In `voice/urls.py`, add after the Agent methodology assignment line (~line 41) and before the Sales Agent dashboards:

```python
    # Clients
    path('manager/clients/', views.ClientListView.as_view(), name='client_list'),
    path('manager/clients/<int:client_id>/', views.ClientDetailView.as_view(), name='client_detail'),
```

- [ ] **Step 2: Verify URLs resolve**

Run: `python manage.py check`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add voice/urls.py
git commit -m "feat: add client list and detail URL patterns"
```

---

### Task 4: Add Sidebar Navigation Entry

**Files:**
- Modify: `voice/templates/voice/base.html`

- [ ] **Step 1: Add Clients nav item**

In `voice/templates/voice/base.html`, find the "Manage" section (after the Agents link, before Methodologies). Add a "Clients" entry right after the Agents link:

```html
            <a href="{% url 'voice:client_list' %}" class="flex items-center gap-3 px-3 py-2 rounded-lg text-sm mb-0.5 {% if request.resolver_match.url_name == 'client_list' or request.resolver_match.url_name == 'client_detail' %}bg-teal-500/10 text-teal-400 font-medium{% else %}text-slate-400 hover:bg-[#1e293b] hover:text-slate-200{% endif %} transition-colors">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"></path></svg>
                Clients
            </a>
```

- [ ] **Step 2: Verify template renders**

Run: `python manage.py check`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add voice/templates/voice/base.html
git commit -m "feat: add Clients entry to sidebar navigation"
```

---

### Task 5: Create Client List Template

**Files:**
- Create: `voice/templates/voice/manager/client_list.html`

- [ ] **Step 1: Create the template**

Create `voice/templates/voice/manager/client_list.html`:

```html
{% extends 'voice/base.html' %}

{% block title %}Clients - Sales Assistant{% endblock %}

{% block page_header %}
<div class="flex items-center justify-between">
    <div>
        <h1 class="text-xl font-bold text-slate-900">Clients</h1>
        <p class="text-sm text-slate-500">{{ total_count }} client{{ total_count|pluralize }} &middot; {{ with_summary }} with AI summary</p>
    </div>
</div>
{% endblock %}

{% block content %}

<!-- Search -->
<form method="get" class="mb-5">
    <div class="relative">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 text-slate-400 absolute left-3 top-1/2 -translate-y-1/2" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/></svg>
        <input type="text" name="q" value="{{ search }}"
            class="w-full sm:w-80 h-9 rounded-lg border border-slate-200 text-sm text-slate-700 pl-9 pr-3 focus:outline-none focus:ring-2 focus:ring-teal-500/30 focus:border-teal-400 placeholder-slate-300"
            placeholder="Search clients by name, industry, or domain...">
    </div>
</form>

{% if clients %}
<div class="bg-white rounded-xl border border-slate-200">
    <div class="overflow-x-auto">
        <table class="w-full">
            <thead>
                <tr class="text-left text-[10px] uppercase text-slate-400 tracking-wider border-b border-slate-100">
                    <th class="py-3 px-4 font-medium">Client</th>
                    <th class="py-3 px-4 font-medium">Industry</th>
                    <th class="py-3 px-4 font-medium">Visits</th>
                    <th class="py-3 px-4 font-medium">Agents</th>
                    <th class="py-3 px-4 font-medium">Intel</th>
                    <th class="py-3 px-4 font-medium">Last Synced</th>
                </tr>
            </thead>
            <tbody class="text-sm">
                {% for item in clients %}
                <tr class="border-t border-slate-50 hover:bg-slate-50/50 transition-colors cursor-pointer"
                    onclick="window.location='{% url 'voice:client_detail' item.client.id %}'">
                    <td class="py-3 px-4">
                        <div class="font-semibold text-slate-800">{{ item.client.name }}</div>
                        {% if item.client.domain %}
                        <div class="text-xs text-slate-400">{{ item.client.domain }}</div>
                        {% endif %}
                    </td>
                    <td class="py-3 px-4 text-slate-600">{{ item.client.industry|default:"—" }}</td>
                    <td class="py-3 px-4">
                        <span class="text-slate-800 font-medium">{{ item.total_visits }}</span>
                        {% if item.last_visit %}
                        <span class="text-xs text-slate-400 ml-1">last {{ item.last_visit.start_time|date:"M d" }}</span>
                        {% endif %}
                    </td>
                    <td class="py-3 px-4 text-slate-600">{{ item.agent_count }}</td>
                    <td class="py-3 px-4">
                        <div class="flex items-center gap-2">
                            <div class="flex items-center gap-1" title="{% if item.has_summary %}AI summary available{% else %}No AI summary{% endif %}">
                                <div class="w-2 h-2 rounded-full {% if item.has_summary %}bg-emerald-500{% else %}bg-slate-200{% endif %}"></div>
                                <span class="text-[10px] text-slate-400">AI</span>
                            </div>
                            <div class="flex items-center gap-1" title="{% if item.has_contacts %}Contacts synced{% else %}No contacts{% endif %}">
                                <div class="w-2 h-2 rounded-full {% if item.has_contacts %}bg-emerald-500{% else %}bg-slate-200{% endif %}"></div>
                                <span class="text-[10px] text-slate-400">CRM</span>
                            </div>
                        </div>
                    </td>
                    <td class="py-3 px-4">
                        {% if item.client.last_synced_at %}
                        <div class="flex items-center gap-1.5">
                            <div class="w-2 h-2 rounded-full {% if item.is_stale %}bg-amber-400{% else %}bg-emerald-500{% endif %}"></div>
                            <span class="text-xs text-slate-400">{{ item.client.last_synced_at|timesince }} ago</span>
                        </div>
                        {% else %}
                        <div class="flex items-center gap-1.5">
                            <div class="w-2 h-2 rounded-full bg-slate-200"></div>
                            <span class="text-xs text-slate-300">Never</span>
                        </div>
                        {% endif %}
                    </td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
    </div>
</div>
{% else %}
<div class="bg-white rounded-xl border border-slate-200 p-12 text-center">
    <svg xmlns="http://www.w3.org/2000/svg" class="h-10 w-10 text-slate-200 mx-auto mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"/>
    </svg>
    {% if search %}
    <p class="text-sm text-slate-500 mb-1">No clients matching "{{ search }}"</p>
    <a href="{% url 'voice:client_list' %}" class="text-xs text-teal-600 hover:text-teal-700">Clear search</a>
    {% else %}
    <p class="text-sm text-slate-500 mb-1">No clients yet</p>
    <p class="text-xs text-slate-400">Clients are synced automatically from your CRM</p>
    {% endif %}
</div>
{% endif %}

{% endblock %}
```

- [ ] **Step 2: Verify template renders**

```bash
python -c "
import django, os
os.environ['DJANGO_SETTINGS_MODULE'] = 'proj_mes_voice.settings'
django.setup()
from django.test import Client
c = Client(SERVER_NAME='localhost')
c.login(username='admin', password='admin123')
resp = c.get('/manager/clients/')
print('Status:', resp.status_code)
content = resp.content.decode()
for term in ['Clients', 'AI summary', 'Search']:
    print(f'  {term}: {term in content}')
"
```

Expected: Status 200, all sections present

- [ ] **Step 3: Commit**

```bash
git add voice/templates/voice/manager/client_list.html
git commit -m "feat: add client list template"
```

---

### Task 6: Create Client Detail Template

**Files:**
- Create: `voice/templates/voice/manager/client_detail.html`

- [ ] **Step 1: Create the template**

Create `voice/templates/voice/manager/client_detail.html`:

```html
{% extends 'voice/base.html' %}

{% block title %}{{ client.name }} - Sales Assistant{% endblock %}

{% block page_header %}
<div>
    <div class="flex items-center gap-2 text-xs text-slate-400 mb-1">
        <a href="{% url 'voice:client_list' %}" class="hover:text-teal-600 transition-colors">Clients</a>
        <span>/</span>
        <span class="text-slate-500">{{ client.name }}</span>
    </div>
    <h1 class="text-xl font-bold text-slate-900">{{ client.name }}</h1>
    <div class="flex items-center gap-3 mt-1">
        {% if client.industry %}
        <span class="text-sm text-slate-500">{{ client.industry }}</span>
        {% endif %}
        {% if client.domain %}
        <span class="text-slate-300">|</span>
        <span class="text-sm text-slate-400">{{ client.domain }}</span>
        {% endif %}
        {% if client.last_synced_at %}
        <span class="text-slate-300">|</span>
        <span class="text-xs text-slate-400">Synced {{ client.last_synced_at|timesince }} ago</span>
        {% endif %}
    </div>
</div>
{% endblock %}

{% block content %}

<!-- Stats Strip -->
<div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
    <div class="bg-white rounded-xl border border-slate-200 px-4 py-3 text-center">
        <div class="text-2xl font-bold text-slate-900">{{ total_visits }}</div>
        <div class="text-[10px] text-slate-400 uppercase">Total Visits</div>
    </div>
    <div class="bg-white rounded-xl border border-slate-200 px-4 py-3 text-center">
        <div class="text-2xl font-bold text-emerald-600">{{ completed_visits }}</div>
        <div class="text-[10px] text-slate-400 uppercase">Completed</div>
    </div>
    <div class="bg-white rounded-xl border border-slate-200 px-4 py-3 text-center">
        <div class="text-2xl font-bold text-slate-800">{{ completion_rate }}%</div>
        <div class="text-[10px] text-slate-400 uppercase">Completion</div>
    </div>
    <div class="bg-white rounded-xl border border-slate-200 px-4 py-3 text-center">
        <div class="text-2xl font-bold text-slate-800">{{ agents|length }}</div>
        <div class="text-[10px] text-slate-400 uppercase">Agents</div>
    </div>
</div>

<!-- Main Content: 2 columns -->
<div class="grid grid-cols-1 lg:grid-cols-3 gap-6">

    <!-- Left: Visits + Calls -->
    <div class="lg:col-span-2 space-y-6">

        <!-- Visit History -->
        <div>
            <h2 class="text-sm font-semibold text-slate-500 uppercase tracking-wider mb-3">Visit History</h2>
            {% if visits %}
            <div class="bg-white rounded-xl border border-slate-200">
                <div class="overflow-x-auto">
                    <table class="w-full">
                        <thead>
                            <tr class="text-left text-[10px] uppercase text-slate-400 tracking-wider border-b border-slate-100">
                                <th class="py-3 px-4 font-medium">Date</th>
                                <th class="py-3 px-4 font-medium">Agent</th>
                                <th class="py-3 px-4 font-medium">Methodology</th>
                                <th class="py-3 px-4 font-medium">Status</th>
                            </tr>
                        </thead>
                        <tbody class="text-sm">
                            {% for visit in visits %}
                            <tr class="border-t border-slate-50 hover:bg-slate-50/50 transition-colors cursor-pointer"
                                onclick="window.location='{% url 'voice:visit_detail' visit.id %}'">
                                <td class="py-2.5 px-4 text-slate-600 whitespace-nowrap">
                                    {{ visit.start_time|date:"M d, Y" }}
                                    <span class="text-xs text-slate-400 ml-1">{{ visit.start_time|date:"H:i" }}</span>
                                </td>
                                <td class="py-2.5 px-4">
                                    <div class="flex items-center gap-2">
                                        <div class="w-5 h-5 rounded-full bg-slate-800 flex items-center justify-center text-white text-[9px] font-bold">{{ visit.agent.username|first|upper }}</div>
                                        <span class="text-slate-700">{{ visit.agent.get_full_name|default:visit.agent.username }}</span>
                                    </div>
                                </td>
                                <td class="py-2.5 px-4">
                                    {% if visit.methodology %}
                                    <span class="inline-block px-1.5 py-0.5 rounded bg-slate-100 text-[10px] font-medium text-slate-600">{{ visit.methodology.name }}</span>
                                    {% else %}
                                    <span class="text-slate-300">&mdash;</span>
                                    {% endif %}
                                </td>
                                <td class="py-2.5 px-4">
                                    <span class="inline-block px-2 py-0.5 rounded-full text-[10px] font-semibold
                                        {% if visit.status == 'COMPLETE' %}bg-emerald-100 text-emerald-700
                                        {% elif visit.status == 'POST_CALL_DONE' %}bg-indigo-100 text-indigo-700
                                        {% elif visit.status == 'PRE_CALL_DONE' %}bg-teal-100 text-teal-700
                                        {% elif visit.status == 'IN_PROGRESS' %}bg-blue-100 text-blue-700
                                        {% else %}bg-slate-100 text-slate-500{% endif %}">
                                        {{ visit.get_status_display }}
                                    </span>
                                </td>
                            </tr>
                            {% endfor %}
                        </tbody>
                    </table>
                </div>
            </div>
            {% else %}
            <div class="bg-white rounded-xl border border-slate-200 p-6 text-center">
                <p class="text-sm text-slate-400">No visits with this client yet</p>
            </div>
            {% endif %}
        </div>

        <!-- Recent Calls -->
        {% if recent_calls %}
        <div>
            <h2 class="text-sm font-semibold text-slate-500 uppercase tracking-wider mb-3">Recent Calls</h2>
            <div class="bg-white rounded-xl border border-slate-200 divide-y divide-slate-50">
                {% for call in recent_calls %}
                <div class="px-4 py-3 flex items-center justify-between">
                    <div class="flex items-center gap-3">
                        <span class="inline-block px-2 py-0.5 rounded-full text-[10px] font-semibold
                            {% if call.phase == 'PRE' %}bg-teal-100 text-teal-700{% else %}bg-indigo-100 text-indigo-700{% endif %}">
                            {% if call.phase == 'PRE' %}Pre{% else %}Post{% endif %}
                        </span>
                        <span class="text-sm text-slate-700">{{ call.visit.agent.get_full_name|default:call.visit.agent.username }}</span>
                        <span class="inline-block px-2 py-0.5 rounded-full text-[10px] font-semibold
                            {% if call.status == 'COMPLETED' %}bg-emerald-100 text-emerald-700
                            {% elif call.status == 'FAILED' %}bg-red-100 text-red-700
                            {% elif call.status == 'NO_ANSWER' %}bg-amber-100 text-amber-700
                            {% else %}bg-slate-100 text-slate-500{% endif %}">
                            {{ call.get_status_display }}
                        </span>
                    </div>
                    <span class="text-xs text-slate-400">{{ call.created_at|date:"M d, H:i" }}</span>
                </div>
                {% endfor %}
            </div>
        </div>
        {% endif %}

    </div>

    <!-- Right: Client Intel -->
    <div class="space-y-6">

        <!-- AI Summary -->
        <div class="bg-white rounded-xl border border-slate-200 p-5">
            <h2 class="text-sm font-semibold text-slate-500 uppercase tracking-wider mb-3">AI Summary</h2>
            {% if client.ai_summary %}
            <div class="text-xs text-slate-600 leading-relaxed whitespace-pre-wrap">{{ client.ai_summary }}</div>
            {% else %}
            <div class="text-center py-4">
                <div class="w-2.5 h-2.5 rounded-full bg-amber-400 mx-auto mb-2"></div>
                <p class="text-xs text-slate-400">No AI summary generated yet</p>
                <p class="text-[10px] text-slate-300 mt-1">Summary is generated during CRM sync when ANTHROPIC_API_KEY is configured</p>
            </div>
            {% endif %}
        </div>

        <!-- Contacts -->
        <div class="bg-white rounded-xl border border-slate-200 p-5">
            <h2 class="text-sm font-semibold text-slate-500 uppercase tracking-wider mb-3">Contacts</h2>
            {% if client.contacts %}
            <div class="space-y-2">
                {% for contact in client.contacts %}
                <div class="flex items-center justify-between text-xs">
                    <div>
                        <div class="font-medium text-slate-700">{{ contact.name|default:"Unknown" }}</div>
                        {% if contact.email %}<div class="text-slate-400">{{ contact.email }}</div>{% endif %}
                    </div>
                    {% if contact.phone %}<span class="text-slate-400">{{ contact.phone }}</span>{% endif %}
                </div>
                {% endfor %}
            </div>
            {% else %}
            <p class="text-xs text-slate-400 text-center py-2">No contacts synced</p>
            {% endif %}
        </div>

        <!-- Agents Working This Client -->
        {% if agents %}
        <div class="bg-white rounded-xl border border-slate-200 p-5">
            <h2 class="text-sm font-semibold text-slate-500 uppercase tracking-wider mb-3">Assigned Agents</h2>
            <div class="space-y-2">
                {% for agent in agents %}
                <div class="flex items-center gap-2">
                    <div class="w-6 h-6 rounded-full bg-slate-800 flex items-center justify-center text-white text-[9px] font-bold">{{ agent.username|first|upper }}</div>
                    <div>
                        <div class="text-xs font-medium text-slate-700">{{ agent.get_full_name|default:agent.username }}</div>
                        {% if agent.default_methodology %}
                        <div class="text-[10px] text-slate-400">{{ agent.default_methodology.name }}</div>
                        {% endif %}
                    </div>
                </div>
                {% endfor %}
            </div>
        </div>
        {% endif %}

        <!-- CRM Info -->
        <div class="bg-white rounded-xl border border-slate-200 p-5">
            <h2 class="text-sm font-semibold text-slate-500 uppercase tracking-wider mb-3">CRM Data</h2>
            <div class="space-y-2 text-xs">
                <div class="flex items-center justify-between">
                    <span class="text-slate-400">CRM ID</span>
                    <span class="text-slate-600 font-mono">{{ client.crm_id }}</span>
                </div>
                {% if client.domain %}
                <div class="flex items-center justify-between">
                    <span class="text-slate-400">Domain</span>
                    <span class="text-slate-600">{{ client.domain }}</span>
                </div>
                {% endif %}
                <div class="flex items-center justify-between">
                    <span class="text-slate-400">Deals</span>
                    <span class="text-slate-600">{{ client.deal_history|length }}</span>
                </div>
                <div class="flex items-center justify-between">
                    <span class="text-slate-400">Interactions</span>
                    <span class="text-slate-600">{{ client.interaction_history|length }}</span>
                </div>
            </div>
        </div>

    </div>
</div>

{% endblock %}
```

- [ ] **Step 2: Verify template renders with a real client**

```bash
python -c "
import django, os
os.environ['DJANGO_SETTINGS_MODULE'] = 'proj_mes_voice.settings'
django.setup()
from voice.models import Client
from django.test import Client as TC
c = TC(SERVER_NAME='localhost')
c.login(username='admin', password='admin123')
client = Client.objects.first()
resp = c.get(f'/manager/clients/{client.id}/')
print('Status:', resp.status_code)
content = resp.content.decode()
for term in ['Visit History', 'AI Summary', 'Contacts', 'CRM Data', client.name]:
    print(f'  {term}: {term in content}')
"
```

Expected: Status 200, all sections present, client name visible

- [ ] **Step 3: Commit**

```bash
git add voice/templates/voice/manager/client_detail.html
git commit -m "feat: add client detail template"
```

---

### Task 7: Final Verification

- [ ] **Step 1: Run Django system check**

Run: `python manage.py check`
Expected: No errors

- [ ] **Step 2: Verify all pages render**

```bash
python -c "
import django, os
os.environ['DJANGO_SETTINGS_MODULE'] = 'proj_mes_voice.settings'
django.setup()
from django.test import Client as TC
from voice.models import Client
c = TC(SERVER_NAME='localhost')
c.login(username='admin', password='admin123')

# Client list
resp = c.get('/manager/clients/')
print('List:', resp.status_code)

# Client list with search
resp = c.get('/manager/clients/?q=acme')
print('Search:', resp.status_code)

# Client detail
client = Client.objects.first()
resp = c.get(f'/manager/clients/{client.id}/')
print('Detail:', resp.status_code)

# Verify sidebar has Clients link
resp = c.get('/dashboard/admin/')
print('Sidebar has Clients:', 'client_list' in resp.content.decode())
"
```

Expected: All 200, sidebar link present

- [ ] **Step 3: Commit all remaining changes**

```bash
git add -A
git commit -m "feat: complete clients section with list, detail, and sidebar nav"
```
