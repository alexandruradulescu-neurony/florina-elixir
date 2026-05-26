# Live Agent Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Live Agent" chat page where the sales manager can ask natural language questions about their data (clients, visits, calls, agents) and get instant answers powered by Claude API.

**Architecture:** A new Django view serves a chat page with vanilla JS for the UI. Messages are sent via AJAX POST to a backend endpoint that assembles database context (counts, recent records, specific lookups), sends the conversation to Claude API with a system prompt describing the data schema, and returns the answer. Session-based message history (not persisted to DB). Uses existing `voice/services/llm.py` for Claude API access, extended with a new `chat_with_data()` function.

**Tech Stack:** Django 4.2, Anthropic Claude API (existing), vanilla JavaScript (fetch + DOM), Tailwind CSS

---

### File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `voice/services/llm.py` | Modify | Add `chat_with_data()` function for multi-turn conversation |
| `voice/services/data_context.py` | Create | Assembles database snapshot as text context for the LLM |
| `voice/views.py` | Modify | Add `LiveAgentView` (GET=page) and `LiveAgentChatAPI` (POST=message) |
| `voice/urls.py` | Modify | Add 2 URL patterns |
| `voice/templates/voice/base.html` | Modify | Add "Live Agent" nav item to sidebar Overview section |
| `voice/templates/voice/manager/live_agent.html` | Create | Chat interface template |

---

### Task 1: Create Data Context Service

**Files:**
- Create: `voice/services/data_context.py`

- [ ] **Step 1: Create the data context assembler**

Create `voice/services/data_context.py`:

```python
"""
Assembles a database snapshot as text context for the Live Agent chat.
Provides the LLM with current data so it can answer questions accurately.
"""
from django.utils import timezone
from datetime import timedelta


def assemble_data_context():
    """
    Build a text summary of current database state for the LLM.
    Returns a string with structured data the LLM can reference.
    """
    from voice.models import User, Client, Visit, CallAttempt, Methodology, GlobalSettings
    from voice.constants import VisitStatus, CallStatus

    now = timezone.now()
    today = now.date()
    week_start = today - timedelta(days=today.weekday())
    week_end = week_start + timedelta(days=6)

    # Agents
    agents = User.objects.filter(is_sales_agent=True).select_related('default_methodology')
    agent_lines = []
    for a in agents:
        methodology = a.default_methodology.name if a.default_methodology else 'None'
        phone = a.phone_number or 'No phone'
        agent_lines.append(
            f"  - {a.get_full_name() or a.username} (username: {a.username}, "
            f"methodology: {methodology}, phone: {phone})"
        )

    # Clients
    clients = Client.objects.all().order_by('name')
    client_lines = []
    for c in clients:
        visit_count = Visit.objects.filter(client=c).count()
        client_lines.append(
            f"  - {c.name} (industry: {c.industry or 'N/A'}, "
            f"domain: {c.domain or 'N/A'}, visits: {visit_count})"
        )

    # Today's visits
    today_visits = Visit.objects.filter(
        start_time__date=today
    ).select_related('agent', 'client', 'methodology').order_by('start_time')
    visit_lines = []
    for v in today_visits:
        client_name = v.client.name if v.client else 'Unknown'
        agent_name = v.agent.get_full_name() or v.agent.username
        methodology = v.methodology.name if v.methodology else 'Default'
        visit_lines.append(
            f"  - {v.start_time.strftime('%H:%M')}-{v.end_time.strftime('%H:%M')} "
            f"{agent_name} -> {client_name} [{v.get_status_display()}] "
            f"(methodology: {methodology})"
        )

    # This week's visits summary
    week_visits = Visit.objects.filter(
        start_time__date__gte=week_start,
        start_time__date__lte=week_end,
    )
    week_total = week_visits.count()
    week_complete = week_visits.filter(status=VisitStatus.COMPLETE).count()
    week_planned = week_visits.filter(status=VisitStatus.PLANNED).count()

    # Calls summary
    today_calls = CallAttempt.objects.filter(created_at__date=today)
    total_calls_today = today_calls.count()
    completed_calls_today = today_calls.filter(status=CallStatus.COMPLETED).count()
    failed_calls_today = today_calls.filter(
        status__in=[CallStatus.FAILED, CallStatus.NO_ANSWER]
    ).count()

    all_calls = CallAttempt.objects.all()
    total_calls_ever = all_calls.count()
    completed_calls_ever = all_calls.filter(status=CallStatus.COMPLETED).count()

    # Methodologies
    methodologies = Methodology.objects.filter(is_active=True)
    methodology_lines = []
    for m in methodologies:
        agent_count = User.objects.filter(
            is_sales_agent=True, default_methodology=m
        ).count()
        methodology_lines.append(f"  - {m.name} (used by {agent_count} agents)")

    # Global settings
    settings = GlobalSettings.load()
    default_method = settings.default_methodology.name if settings.default_methodology else 'None'

    context = f"""## Current Date & Time
{now.strftime('%A, %B %d, %Y at %H:%M')}

## Sales Agents ({agents.count()})
{chr(10).join(agent_lines) if agent_lines else '  No agents configured'}

## Clients ({clients.count()})
{chr(10).join(client_lines) if client_lines else '  No clients synced'}

## Today's Visits ({len(visit_lines)})
{chr(10).join(visit_lines) if visit_lines else '  No visits today'}

## This Week (Mon {week_start.strftime('%b %d')} - Sun {week_end.strftime('%b %d')})
  Total: {week_total} | Complete: {week_complete} | Planned: {week_planned}

## Calls
  Today: {total_calls_today} total, {completed_calls_today} completed, {failed_calls_today} failed
  All time: {total_calls_ever} total, {completed_calls_ever} completed

## Active Methodologies ({methodologies.count()})
{chr(10).join(methodology_lines) if methodology_lines else '  No active methodologies'}

## System Settings
  Pre-call offset: {settings.pre_call_offset_minutes} min
  Post-call offset: {settings.post_call_offset_minutes} min
  Default methodology: {default_method}
"""
    return context
```

- [ ] **Step 2: Verify no syntax errors**

Run: `python manage.py check`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add voice/services/data_context.py
git commit -m "feat: add data context assembler for live agent chat"
```

---

### Task 2: Add Chat Function to LLM Service

**Files:**
- Modify: `voice/services/llm.py`

- [ ] **Step 1: Add `chat_with_data` function**

Append to `voice/services/llm.py` after the `extract_pdf_text` function:

```python
def chat_with_data(messages: list, data_context: str) -> Optional[str]:
    """
    Multi-turn chat with database context for the Live Agent feature.

    Args:
        messages: List of {"role": "user"|"assistant", "content": "..."} dicts.
        data_context: Assembled database snapshot text.

    Returns:
        Assistant response text, or None on failure.
    """
    system_prompt = (
        "You are a Sales Assistant AI — a helpful data analyst for a sales manager. "
        "You have access to the current state of the sales database below. "
        "Answer questions accurately based on this data. "
        "Be concise and direct. Use numbers when available. "
        "If you don't have enough data to answer, say so honestly. "
        "Format responses with markdown when helpful (lists, bold, tables). "
        "Never make up data — only reference what's in the context below.\n\n"
        f"## DATABASE SNAPSHOT\n{data_context}"
    )
    try:
        client = _get_client()
        response = client.messages.create(
            model=config('LLM_MODEL', default='claude-sonnet-4-20250514'),
            max_tokens=2048,
            system=system_prompt,
            messages=messages,
        )
        return response.content[0].text
    except Exception as e:
        logger.error(f"Live agent chat failed: {e}", exc_info=True)
        return None
```

- [ ] **Step 2: Verify no syntax errors**

Run: `python manage.py check`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add voice/services/llm.py
git commit -m "feat: add multi-turn chat_with_data for live agent"
```

---

### Task 3: Add Views

**Files:**
- Modify: `voice/views.py`

- [ ] **Step 1: Add LiveAgentView and LiveAgentChatAPI**

Add these two classes to `voice/views.py` after the `ClientDetailView` class (before the Visit Calendar section):

```python
class LiveAgentView(SuperuserRequiredMixin, View):
    """Live Agent chat page — conversational data assistant."""

    def get(self, request):
        from .services.llm import is_configured
        context = {
            'llm_configured': is_configured(),
        }
        return render(request, 'voice/manager/live_agent.html', context)


class LiveAgentChatAPI(SuperuserRequiredMixin, View):
    """AJAX endpoint for Live Agent chat messages."""

    def post(self, request):
        import json
        from django.http import JsonResponse
        from .services.llm import chat_with_data, is_configured
        from .services.data_context import assemble_data_context

        if not is_configured():
            return JsonResponse({
                'error': 'ANTHROPIC_API_KEY not configured'
            }, status=503)

        try:
            body = json.loads(request.body)
            user_message = body.get('message', '').strip()
        except (json.JSONDecodeError, AttributeError):
            return JsonResponse({'error': 'Invalid request'}, status=400)

        if not user_message:
            return JsonResponse({'error': 'Empty message'}, status=400)

        # Get or init session conversation history
        if 'live_agent_history' not in request.session:
            request.session['live_agent_history'] = []

        history = request.session['live_agent_history']

        # Add user message
        history.append({'role': 'user', 'content': user_message})

        # Assemble fresh data context
        data_context = assemble_data_context()

        # Call Claude with full conversation
        response_text = chat_with_data(history, data_context)

        if response_text is None:
            # Remove the failed user message
            history.pop()
            request.session.modified = True
            return JsonResponse({
                'error': 'Failed to get response from AI'
            }, status=500)

        # Add assistant response
        history.append({'role': 'assistant', 'content': response_text})

        # Keep history manageable (last 20 messages)
        if len(history) > 20:
            history = history[-20:]

        request.session['live_agent_history'] = history
        request.session.modified = True

        return JsonResponse({'response': response_text})
```

- [ ] **Step 2: Add JsonResponse import if needed**

Check if `JsonResponse` is already imported at the top of views.py. If not, the inline import in the method handles it.

- [ ] **Step 3: Verify no syntax errors**

Run: `python manage.py check`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add voice/views.py
git commit -m "feat: add LiveAgentView and chat API endpoint"
```

---

### Task 4: Add URL Patterns

**Files:**
- Modify: `voice/urls.py`

- [ ] **Step 1: Add live agent URLs**

In `voice/urls.py`, add after the client URLs and before the Sales Agent dashboards:

```python
    # Live Agent
    path('manager/agent-chat/', views.LiveAgentView.as_view(), name='live_agent'),
    path('manager/agent-chat/api/', views.LiveAgentChatAPI.as_view(), name='live_agent_api'),
```

- [ ] **Step 2: Verify**

Run: `python manage.py check`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add voice/urls.py
git commit -m "feat: add live agent chat URL patterns"
```

---

### Task 5: Add Sidebar Navigation Entry

**Files:**
- Modify: `voice/templates/voice/base.html`

- [ ] **Step 1: Add Live Agent nav item**

In `voice/templates/voice/base.html`, find the Calendar link in the Overview section (~line 76, right before the `<div>Manage</div>` section). Add the Live Agent entry after Calendar:

```html
            <a href="{% url 'voice:live_agent' %}" class="flex items-center gap-3 px-3 py-2 rounded-lg text-sm mb-0.5 {% if request.resolver_match.url_name == 'live_agent' %}bg-teal-500/10 text-teal-400 font-medium{% else %}text-slate-400 hover:bg-[#1e293b] hover:text-slate-200{% endif %} transition-colors">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 10h.01M12 10h.01M16 10h.01M9 16H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-5l-5 5v-5z"></path></svg>
                Live Agent
            </a>
```

- [ ] **Step 2: Commit**

```bash
git add voice/templates/voice/base.html
git commit -m "feat: add Live Agent to sidebar navigation"
```

---

### Task 6: Create Chat Template

**Files:**
- Create: `voice/templates/voice/manager/live_agent.html`

- [ ] **Step 1: Create the chat template**

Create `voice/templates/voice/manager/live_agent.html`:

```html
{% extends 'voice/base.html' %}

{% block title %}Live Agent - Sales Assistant{% endblock %}

{% block page_header %}
<div class="flex items-center justify-between">
    <div>
        <h1 class="text-xl font-bold text-slate-900">Live Agent</h1>
        <p class="text-sm text-slate-500">Ask questions about your sales data</p>
    </div>
    <button onclick="clearChat()" class="px-3 h-8 rounded-lg border border-slate-200 text-xs font-medium text-slate-500 hover:bg-slate-50 transition-colors">
        Clear Chat
    </button>
</div>
{% endblock %}

{% block content %}

{% if not llm_configured %}
<div class="rounded-xl bg-amber-50 border border-amber-200 px-4 py-3 mb-5">
    <div class="flex items-center gap-2">
        <div class="w-2.5 h-2.5 rounded-full bg-amber-400"></div>
        <span class="text-sm text-amber-800 font-medium">AI not configured</span>
    </div>
    <p class="text-xs text-amber-700 mt-1">Add <code class="bg-amber-100 px-1 rounded">ANTHROPIC_API_KEY</code> to your .env file to enable the Live Agent.</p>
</div>
{% endif %}

<div class="flex flex-col h-[calc(100vh-220px)] max-w-4xl">
    <!-- Messages area -->
    <div id="chat-messages" class="flex-1 overflow-y-auto space-y-4 pb-4">
        <!-- Welcome message -->
        <div id="welcome-message" class="text-center py-12">
            <div class="w-12 h-12 rounded-full bg-teal-500 flex items-center justify-center mx-auto mb-3">
                <svg class="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 10h.01M12 10h.01M16 10h.01M9 16H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-5l-5 5v-5z"></path></svg>
            </div>
            <h2 class="text-lg font-semibold text-slate-800 mb-1">Sales Data Assistant</h2>
            <p class="text-sm text-slate-400 mb-4">Ask me anything about your clients, visits, calls, and agents</p>
            <div class="flex flex-wrap justify-center gap-2">
                <button onclick="sendSuggestion(this)" class="px-3 py-1.5 rounded-lg border border-slate-200 text-xs text-slate-600 hover:bg-slate-50 transition-colors">How many visits are scheduled today?</button>
                <button onclick="sendSuggestion(this)" class="px-3 py-1.5 rounded-lg border border-slate-200 text-xs text-slate-600 hover:bg-slate-50 transition-colors">Which agents have the most visits this week?</button>
                <button onclick="sendSuggestion(this)" class="px-3 py-1.5 rounded-lg border border-slate-200 text-xs text-slate-600 hover:bg-slate-50 transition-colors">What's the overall call success rate?</button>
                <button onclick="sendSuggestion(this)" class="px-3 py-1.5 rounded-lg border border-slate-200 text-xs text-slate-600 hover:bg-slate-50 transition-colors">List all clients and their visit counts</button>
            </div>
        </div>
    </div>

    <!-- Input area -->
    <div class="border-t border-slate-200 pt-4">
        <form id="chat-form" onsubmit="sendMessage(event)" class="flex gap-3">
            <input type="text" id="chat-input"
                class="flex-1 h-10 rounded-lg border border-slate-200 text-sm text-slate-700 px-4 focus:outline-none focus:ring-2 focus:ring-teal-500/30 focus:border-teal-400 placeholder-slate-300"
                placeholder="Ask about your sales data..."
                autocomplete="off"
                {% if not llm_configured %}disabled{% endif %}>
            <button type="submit" id="send-btn"
                class="h-10 px-5 rounded-lg bg-teal-500 hover:bg-teal-600 disabled:bg-slate-200 disabled:text-slate-400 text-white text-sm font-medium transition-colors"
                {% if not llm_configured %}disabled{% endif %}>
                Send
            </button>
        </form>
    </div>
</div>

<script>
const csrfToken = '{{ csrf_token }}';
const chatMessages = document.getElementById('chat-messages');
const chatInput = document.getElementById('chat-input');
const sendBtn = document.getElementById('send-btn');
const welcomeMessage = document.getElementById('welcome-message');

function addMessage(role, content) {
    if (welcomeMessage) welcomeMessage.remove();

    const div = document.createElement('div');
    div.className = role === 'user'
        ? 'flex justify-end'
        : 'flex justify-start';

    const bubble = document.createElement('div');
    bubble.className = role === 'user'
        ? 'max-w-[75%] rounded-xl px-4 py-3 bg-teal-500 text-white text-sm'
        : 'max-w-[75%] rounded-xl px-4 py-3 bg-white border border-slate-200 text-sm text-slate-700';

    if (role === 'assistant') {
        // Basic markdown rendering
        let html = content
            .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
            .replace(/\*(.*?)\*/g, '<em>$1</em>')
            .replace(/`(.*?)`/g, '<code class="bg-slate-100 px-1 rounded text-xs">$1</code>')
            .replace(/^### (.*$)/gm, '<h3 class="font-semibold text-slate-800 mt-2 mb-1">$1</h3>')
            .replace(/^## (.*$)/gm, '<h2 class="font-semibold text-slate-800 mt-2 mb-1">$1</h2>')
            .replace(/^- (.*$)/gm, '<li class="ml-4">$1</li>')
            .replace(/^(\d+)\. (.*$)/gm, '<li class="ml-4">$1. $2</li>')
            .replace(/\n\n/g, '<br><br>')
            .replace(/\n/g, '<br>');
        bubble.innerHTML = html;
    } else {
        bubble.textContent = content;
    }

    div.appendChild(bubble);
    chatMessages.appendChild(div);
    chatMessages.scrollTop = chatMessages.scrollHeight;
}

function addLoading() {
    const div = document.createElement('div');
    div.id = 'loading-indicator';
    div.className = 'flex justify-start';
    div.innerHTML = '<div class="rounded-xl px-4 py-3 bg-white border border-slate-200 text-sm text-slate-400"><div class="flex items-center gap-2"><div class="w-1.5 h-1.5 rounded-full bg-teal-400 animate-pulse"></div><div class="w-1.5 h-1.5 rounded-full bg-teal-400 animate-pulse" style="animation-delay:0.2s"></div><div class="w-1.5 h-1.5 rounded-full bg-teal-400 animate-pulse" style="animation-delay:0.4s"></div></div></div>';
    chatMessages.appendChild(div);
    chatMessages.scrollTop = chatMessages.scrollHeight;
}

function removeLoading() {
    const el = document.getElementById('loading-indicator');
    if (el) el.remove();
}

async function sendMessage(e) {
    e.preventDefault();
    const message = chatInput.value.trim();
    if (!message) return;

    chatInput.value = '';
    chatInput.disabled = true;
    sendBtn.disabled = true;

    addMessage('user', message);
    addLoading();

    try {
        const resp = await fetch('{% url "voice:live_agent_api" %}', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-CSRFToken': csrfToken,
            },
            body: JSON.stringify({ message }),
        });

        removeLoading();

        if (resp.ok) {
            const data = await resp.json();
            addMessage('assistant', data.response);
        } else {
            const err = await resp.json().catch(() => ({}));
            addMessage('assistant', err.error || 'Something went wrong. Please try again.');
        }
    } catch (error) {
        removeLoading();
        addMessage('assistant', 'Network error. Please check your connection.');
    }

    chatInput.disabled = false;
    sendBtn.disabled = false;
    chatInput.focus();
}

function sendSuggestion(btn) {
    chatInput.value = btn.textContent;
    document.getElementById('chat-form').dispatchEvent(new Event('submit'));
}

function clearChat() {
    chatMessages.innerHTML = '';
    // Re-add welcome
    location.reload();
}
</script>

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
resp = c.get('/manager/agent-chat/')
print('Status:', resp.status_code)
content = resp.content.decode()
for term in ['Live Agent', 'Sales Data Assistant', 'Ask about your sales data', 'Clear Chat']:
    print(f'  {term}: {term in content}')
"
```

Expected: Status 200, all sections present

- [ ] **Step 3: Commit**

```bash
git add voice/templates/voice/manager/live_agent.html
git commit -m "feat: add live agent chat template with vanilla JS"
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
from django.test import Client
c = Client(SERVER_NAME='localhost')
c.login(username='admin', password='admin123')

# Chat page
resp = c.get('/manager/agent-chat/')
print('Chat page:', resp.status_code)

# Sidebar has Live Agent
content = resp.content.decode()
print('Sidebar:', 'Live Agent' in content)

# API endpoint (should return 400 for empty body)
resp2 = c.post('/manager/agent-chat/api/',
    data='{}', content_type='application/json')
print('API (empty):', resp2.status_code)
"
```

Expected: Chat page 200, Sidebar True, API 400

- [ ] **Step 3: Commit all remaining changes**

```bash
git add -A
git commit -m "feat: complete live agent chat with data context and Claude API"
```
