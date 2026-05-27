# Demo Live Calls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing ElevenLabs integration to the new Visit model so we can trigger real outbound EL voice calls from the Visit Detail page during tomorrow's (2026-05-28) demo.

**Architecture:** Eight tasks on top of branch `settings-screen`. Add a visit-aware EL trigger function, a new POST view + URL, two new form fields with collapsible accordion UI, a webhook guard for visit-linked calls (no `meeting`), and a `seed_demo` management command. Final commit on branch `demo-live-calls`.

**Tech Stack:** Django 4.2, plain `requests` for EL API, existing CallAttempt + Visit models.

**Source spec:** [docs/superpowers/specs/2026-05-26-demo-live-calls-design.md](../specs/2026-05-26-demo-live-calls-design.md)

**Builds on:** branch `settings-screen` at commit `a376e79` (which is the amended spec on top of all prior implementation).

---

## Conventions

- Working directory is the repo root: `/Users/alex/Code/proj-salesassistant`.
- **DO NOT commit per task.** Per the established pattern, work stays uncommitted across all phases; final commit happens in Task 8.
- After every file change, run `python manage.py check` to confirm no template-syntax errors.
- The implementer will dispatch a fresh subagent per task; each subagent must NOT commit.

---

## Task 1: Add `trigger_visit_call(visit, phase)` to `voice/services/elevenlabs.py`

**Files:**
- Modify: `voice/services/elevenlabs.py` (append a new function at the end)

**Step 1: Append this function to `voice/services/elevenlabs.py`**

```python


# ============================================================================
# Visit-aware EL trigger (used by the Call Now button on Visit Detail).
# Bypasses the legacy meeting-keyed trigger_agent_call; works with Visit
# directly. The prompt is taken verbatim from visit.pre_call_prompt or
# visit.post_call_prompt — no placeholder interpolation.
# ============================================================================


def trigger_visit_call(visit, phase: str) -> Dict[str, Any]:
    """Initiate an EL outbound call for a Visit and phase ('pre' or 'post').

    - Reads the pre-rendered prompt directly from visit.pre_call_prompt
      or visit.post_call_prompt.
    - Picks the agent's phone from visit.agent.phone_number.
    - Uses settings.ELEVENLABS_AGENT_ID as the shared EL agent.
    - Creates a CallAttempt(visit=visit, meeting=None, phase=..., ...).

    Returns: {'success': bool, 'call_id': str|None, 'error': str|None}.
    """
    from decouple import config
    import requests
    from voice.constants import CallPhase

    result = {'success': False, 'call_id': None, 'error': None}

    # Phase mapping
    if phase == 'pre':
        prompt_text = visit.pre_call_prompt
        call_phase = CallPhase.PRE_MEETING
    elif phase == 'post':
        prompt_text = visit.post_call_prompt
        call_phase = CallPhase.POST_MEETING
    else:
        result['error'] = f"Invalid phase '{phase}'. Expected 'pre' or 'post'."
        return result

    if not prompt_text or not prompt_text.strip():
        result['error'] = (
            f"{phase.title()}-call prompt is empty on visit #{visit.id}. "
            f"Paste it on the Visit Detail page first."
        )
        return result

    # Validate agent phone
    if not visit.agent or not visit.agent.phone_number:
        result['error'] = f"Visit #{visit.id} has no agent phone number on file."
        return result
    formatted_phone = format_phone_number(visit.agent.phone_number)
    if not formatted_phone:
        result['error'] = f"Agent phone '{visit.agent.phone_number}' is not a valid E.164 number."
        return result

    # Validate env vars
    api_key = config('ELEVENLABS_API_KEY', default='')
    agent_id = config('ELEVENLABS_AGENT_ID', default='')
    phone_number_id = config('ELEVENLABS_PHONE_NUMBER_ID', default='')
    missing = [
        name for name, val in (
            ('ELEVENLABS_API_KEY', api_key),
            ('ELEVENLABS_AGENT_ID', agent_id),
            ('ELEVENLABS_PHONE_NUMBER_ID', phone_number_id),
        ) if not val
    ]
    if missing:
        result['error'] = f"Missing env vars: {', '.join(missing)}"
        return result

    # Create CallAttempt row (visit-linked, no meeting)
    call_attempt = CallAttempt.objects.create(
        visit=visit,
        meeting=None,
        phase=call_phase,
        scheduled_offset_minutes=0,
        scheduled_time=timezone.now(),
        executed_at=timezone.now(),
        status=CallStatus.INITIATED,
    )

    # Build EL payload
    payload = {
        'agent_id': agent_id,
        'agent_phone_number_id': phone_number_id,
        'to_number': formatted_phone,
        'conversation_initiation_client_data': {
            'conversation_config_override': {
                'agent': {
                    'prompt': {'prompt': prompt_text.strip()},
                },
            },
        },
    }

    api_url = 'https://api.elevenlabs.io/v1/convai/twilio/outbound-call'
    headers = {
        'Content-Type': 'application/json',
        'xi-api-key': api_key,
    }

    try:
        response = requests.post(api_url, headers=headers, json=payload, timeout=30)
    except requests.exceptions.RequestException as e:
        call_attempt.status = CallStatus.FAILED
        call_attempt.save()
        result['error'] = f"EL request failed: {e}"
        return result

    if response.status_code == 200:
        data = response.json()
        call_id = (
            data.get('conversation_id')
            or data.get('call_id')
            or data.get('id')
            or data.get('call_sid')
        )
        if call_id:
            call_attempt.external_call_id = call_id
            call_attempt.status = CallStatus.IN_PROGRESS
            call_attempt.save()
            result['success'] = True
            result['call_id'] = call_id
            return result
        call_attempt.status = CallStatus.FAILED
        call_attempt.save()
        result['error'] = f"EL returned 200 but no call_id in response: {data}"
        return result

    # Non-200
    try:
        err_data = response.json()
        err_detail = err_data.get('detail') or err_data.get('message') or err_data.get('error') or str(err_data)
    except Exception:
        err_detail = response.text[:200]
    call_attempt.status = CallStatus.FAILED
    call_attempt.save()
    result['error'] = f"EL API error ({response.status_code}): {err_detail}"
    return result
```

**Step 2: Verify**

```bash
python -c "from voice.services.elevenlabs import trigger_visit_call; print(trigger_visit_call.__doc__[:80])"
python manage.py check
```

Expected: docstring prints; check passes.

DO NOT commit.

---

## Task 2: Add URL + `VisitCallNowView` in `voice/urls.py` and `voice/views.py`

**Files:**
- Modify: `voice/urls.py` (add 1 URL pattern)
- Modify: `voice/views.py` (add new view class)

**Step 1: Add URL pattern**

In `voice/urls.py`, locate the line for `visit_detail`:

```python
    path('manager/visits/<int:visit_id>/', views.VisitDetailView.as_view(), name='visit_detail'),
```

Insert this line immediately AFTER it:

```python
    path('manager/visits/<int:visit_id>/call/<str:phase>/', views.VisitCallNowView.as_view(), name='visit_call_now'),
```

**Step 2: Add view class**

In `voice/views.py`, locate the `VisitDetailView` class. Add this new class right after it (after its closing — pick a spot that doesn't break unrelated classes):

```python


class VisitCallNowView(SuperuserRequiredMixin, View):
    """Trigger an EL outbound call for a Visit's pre or post phase."""

    def post(self, request, visit_id, phase):
        from django.shortcuts import get_object_or_404
        from django.contrib import messages
        from voice.services.elevenlabs import trigger_visit_call

        visit = get_object_or_404(Visit, id=visit_id)
        if phase not in ('pre', 'post'):
            messages.error(request, "Invalid call phase.")
            return redirect('voice:visit_detail', visit_id=visit_id)

        result = trigger_visit_call(visit, phase)
        if result['success']:
            messages.success(
                request,
                f"{phase.title()}-call initiated for {visit.client.name if visit.client else 'visit'}. "
                f"Call ID: {result['call_id']}"
            )
        else:
            messages.error(request, f"Call failed: {result['error']}")
        return redirect('voice:visit_detail', visit_id=visit_id)
```

Check that the imports at the top of `voice/views.py` include `messages` (from `django.contrib`) and `redirect` (from `django.shortcuts`). These should already be present from other views. If not, add them.

**Step 3: Verify**

```bash
python manage.py check
python -c "from django.urls import reverse; print(reverse('voice:visit_call_now', kwargs={'visit_id': 1, 'phase': 'pre'}))"
```

Expected: check passes; URL reverses to `/manager/visits/1/call/pre/`.

DO NOT commit.

---

## Task 3: Webhook guard for `meeting is None`

**Files:**
- Modify: `voice/webhook_views.py`

The current handler does `meeting = call_attempt.meeting` and then `meeting.is_pre_call_completed = True`, plus several other places that dereference `call_attempt.meeting`. When the CallAttempt was created by `trigger_visit_call` with `meeting=None`, every one of those calls will raise `AttributeError`.

**Step 1: Read the handler region**

```bash
grep -n "call_attempt.meeting\|meeting\." voice/webhook_views.py | head -30
```

Note every line that does `call_attempt.meeting.something` or uses the `meeting` local var.

**Step 2: Wrap the meeting-bump block in a guard**

Find this region in `voice/webhook_views.py` (around lines 178-200):

```python
            # Update meeting completion status if call was successful
            if call_attempt.status == CallStatus.COMPLETED:
                meeting = call_attempt.meeting
                if call_attempt.phase == CallPhase.PRE_MEETING:
                    meeting.is_pre_call_completed = True
                elif call_attempt.phase == CallPhase.POST_MEETING:
                    meeting.is_post_call_completed = True
                meeting.save()
                ...
```

Replace the `if call_attempt.status == CallStatus.COMPLETED:` block to guard `meeting`. Wrap everything that needs a meeting in `if meeting:`. The full replacement:

```python
            # Update meeting completion status if call was successful
            if call_attempt.status == CallStatus.COMPLETED:
                meeting = call_attempt.meeting
                if meeting:
                    if call_attempt.phase == CallPhase.PRE_MEETING:
                        meeting.is_pre_call_completed = True
                    elif call_attempt.phase == CallPhase.POST_MEETING:
                        meeting.is_post_call_completed = True
                    meeting.save()

                    # Log successful call completion
                    log_activity(
                        meeting=meeting,
                        user=meeting.agent,
                        action=f"{call_attempt.get_phase_display()} call completed",
                        details={
                            'call_id': call_id,
                            'has_transcript': bool(transcript_text),
                            'has_recording': bool(recording_url),
                            'webhook_type': webhook_type,
                            'transcript_length': len(transcript_text) if transcript_text else 0
                        }
                    )

                    # Trigger Pipedrive sync if post-meeting call
                    if call_attempt.phase == CallPhase.POST_MEETING:
                        try:
                            from .services import sync_note_to_pipedrive
                            # Use summary if available, fallback to transcript
                            note_text = call_attempt.summary if call_attempt.summary else transcript_text
                            if note_text:
                                sync_note_to_pipedrive(
                                    deal_id=None,
                                    text=note_text,
                                    meeting=meeting
                                )
                        except Exception as e:
                            logger.error(f"Failed to sync to Pipedrive: {e}", exc_info=True)
                            log_activity(
                                meeting=meeting,
                                action="Pipedrive sync failed after call completion",
                                details={'error': str(e)},
                                level=LogLevel.ERROR
                            )
                # If meeting is None, this is a visit-linked call (new flow).
                # Transcript/summary/recording_url are already saved on call_attempt above.
            else:
                # Handle pre-meeting call failure: create -30 call if -60 failed.
                # This only applies to meeting-linked calls; skip for visit-linked.
                if (call_attempt.meeting and
                    call_attempt.phase == CallPhase.PRE_MEETING and
                    call_attempt.status in [CallStatus.NO_ANSWER, CallStatus.FAILED] and
                    call_attempt.scheduled_offset_minutes == -60):
                    from django.utils import timezone
                    from datetime import timedelta
                    from .constants import PRE_MEETING_OFFSETS

                    existing_30 = CallAttempt.objects.filter(
                        meeting=call_attempt.meeting,
                        phase=CallPhase.PRE_MEETING,
                        scheduled_offset_minutes=PRE_MEETING_OFFSETS[1]
                    ).exists()

                    if not existing_30 and call_attempt.meeting.start_time > timezone.now():
                        scheduled_time = call_attempt.meeting.start_time + timedelta(minutes=PRE_MEETING_OFFSETS[1])
                        CallAttempt.objects.create(
                            meeting=call_attempt.meeting,
                            phase=CallPhase.PRE_MEETING,
                            scheduled_offset_minutes=PRE_MEETING_OFFSETS[1],
                            scheduled_time=scheduled_time,
                            status=CallStatus.SCHEDULED
                        )
                        log_activity(
                            meeting=call_attempt.meeting,
                            user=call_attempt.meeting.agent,
                            action="Created -30 minute retry call after -60 call failed",
                            details={'failed_call_id': call_attempt.id, 'failed_status': call_attempt.status}
                        )

                # Log non-completed status — guard against missing meeting
                if call_attempt.meeting:
                    log_activity(
                        meeting=call_attempt.meeting,
                        user=call_attempt.meeting.agent,
                        action=f"{call_attempt.get_phase_display()} call {call_attempt.get_status_display()}",
                        details={
                            'call_id': call_id,
                            'webhook_type': webhook_type,
                            'status': call_attempt.status,
                        }
                    )
```

Read the surrounding context of the existing block carefully — the exact structure of the `else:` branch (lines ~221-260) should be preserved with only the additional `if call_attempt.meeting:` guard wrapping the `log_activity` call. If the existing `else:` branch has logic beyond what's shown here, preserve it and just add `meeting`-existence guards.

**Step 3: Verify**

```bash
python manage.py check
```

Expected: passes.

DO NOT commit.

---

## Task 4: Extend `VisitManagerNotesForm` with prompt fields

**Files:**
- Modify: `voice/forms.py`

**Step 1: Replace the `VisitManagerNotesForm` class body**

In `voice/forms.py` (around line 146), find:

```python
class VisitManagerNotesForm(forms.ModelForm):
    """Form for manager to add notes and override methodology on a visit."""

    class Meta:
        model = Visit
        fields = ['manager_notes', 'methodology']
        widgets = {
            'manager_notes': forms.Textarea(attrs={
                'class': 'textarea textarea-bordered w-full h-32',
                'placeholder': 'Special requirements for this visit (e.g., "Push for Q3 close", "Ask about new CTO")...',
            }),
            'methodology': forms.Select(attrs={
                'class': 'select select-bordered w-full',
            }),
        }
```

Replace with:

```python
class VisitManagerNotesForm(forms.ModelForm):
    """Form for manager to add notes, override methodology, and paste AI prompts on a visit."""

    class Meta:
        model = Visit
        fields = ['manager_notes', 'methodology', 'pre_call_prompt', 'post_call_prompt']
        widgets = {
            'manager_notes': forms.Textarea(attrs={
                'placeholder': 'Special requirements for this visit (e.g., "Push for Q3 close", "Ask about new CTO")...',
            }),
            'methodology': forms.Select(),
            'pre_call_prompt': forms.Textarea(attrs={
                'placeholder': 'Paste the pre-call AI prompt here. Sent verbatim to ElevenLabs.',
                'style': 'min-height:180px;font-family:ui-monospace,Menlo,monospace;font-size:12px;line-height:1.5;',
            }),
            'post_call_prompt': forms.Textarea(attrs={
                'placeholder': 'Paste the post-call AI prompt here. Sent verbatim to ElevenLabs.',
                'style': 'min-height:180px;font-family:ui-monospace,Menlo,monospace;font-size:12px;line-height:1.5;',
            }),
        }
```

(Note we strip the DaisyUI/Tailwind `class=` attrs because the form is rendered in the new design's `.form-row` chrome which provides styling.)

**Step 2: Verify**

```bash
python manage.py check
python -c "from voice.forms import VisitManagerNotesForm; print(VisitManagerNotesForm.Meta.fields)"
```

Expected: check passes; prints `['manager_notes', 'methodology', 'pre_call_prompt', 'post_call_prompt']`.

DO NOT commit.

---

## Task 5: Update Visit Detail template (accordions + Run AI Call card) + screens.css

**Files:**
- Modify: `voice/templates/voice/manager/visit_detail.html`
- Modify: `static/css/screens.css` (append small CSS for accordion)

**Step 1: Append accordion CSS to `static/css/screens.css`**

Append to the end of `static/css/screens.css`:

```css

/* ============================================================================
   Prompt accordion (used in Visit Detail manager notes form)
   ============================================================================ */
.prompt-accordion {
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-md);
  margin-top: 12px;
  background: var(--bg-card);
}
.prompt-accordion[open] {
  background: var(--zinc-50);
}
.prompt-accordion summary {
  cursor: pointer;
  padding: 10px 14px;
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
  color: var(--fg-strong);
  list-style: none;
  display: flex;
  align-items: center;
  gap: 8px;
}
.prompt-accordion summary::-webkit-details-marker { display: none; }
.prompt-accordion summary::before {
  content: "▸";
  color: var(--fg-muted);
  font-size: 10px;
  transition: transform 100ms ease-out;
}
.prompt-accordion[open] summary::before {
  transform: rotate(90deg);
}
.prompt-accordion textarea {
  display: block;
  width: calc(100% - 28px);
  margin: 0 14px 14px;
  padding: 8px 10px;
  border: 1px solid var(--border-default);
  border-radius: var(--radius-md);
  background: var(--bg-surface);
  resize: vertical;
}
```

**Step 2: Update `voice/templates/voice/manager/visit_detail.html`**

Find the Manager Notes card region (right rail). The current `<form>` for manager notes looks roughly like:

```django
        <div class="dcard notes">
            <h3>Manager Notes</h3>
            <form method="post">
                {% csrf_token %}
                <textarea name="manager_notes" placeholder="Notes about this visit…">{{ form.manager_notes.value|default:"" }}</textarea>
                {% if form.methodology %}
                <div class="fieldrow">
                    <label class="t-meta" style="display:block;margin-bottom:6px;">Methodology override</label>
                    {{ form.methodology }}
                </div>
                {% endif %}
                <div class="fieldrow">
                    <button type="submit" class="btn btn-primary" style="width:100%;justify-content:center;">Save</button>
                </div>
                <div class="savehint">Changes affect future pre/post-call prompts.</div>
            </form>
        </div>
```

Replace it with:

```django
        <div class="dcard notes">
            <h3>Manager Notes</h3>
            <form method="post">
                {% csrf_token %}
                <textarea name="manager_notes" placeholder="Notes about this visit…">{{ form.manager_notes.value|default:"" }}</textarea>
                {% if form.methodology %}
                <div class="fieldrow">
                    <label class="t-meta" style="display:block;margin-bottom:6px;">Methodology override</label>
                    {{ form.methodology }}
                </div>
                {% endif %}

                <details class="prompt-accordion">
                    <summary>Pre-call prompt</summary>
                    <textarea name="pre_call_prompt" placeholder="Paste the pre-call AI prompt here. Sent verbatim to ElevenLabs.">{{ form.pre_call_prompt.value|default:'' }}</textarea>
                </details>
                <details class="prompt-accordion">
                    <summary>Post-call prompt</summary>
                    <textarea name="post_call_prompt" placeholder="Paste the post-call AI prompt here. Sent verbatim to ElevenLabs.">{{ form.post_call_prompt.value|default:'' }}</textarea>
                </details>

                <div class="fieldrow" style="margin-top:12px;">
                    <button type="submit" class="btn btn-primary" style="width:100%;justify-content:center;">Save</button>
                </div>
                <div class="savehint">Changes affect future pre/post-call prompts.</div>
            </form>
        </div>

        {# ─── Run AI call ─── #}
        <div class="dcard">
            <h3>Run AI call</h3>
            <form method="post" action="{% url 'voice:visit_call_now' visit_id=visit.id phase='pre' %}" style="margin-bottom:8px;">
                {% csrf_token %}
                <button type="submit" class="btn btn-primary" style="width:100%;justify-content:center;">Run pre-call</button>
            </form>
            <form method="post" action="{% url 'voice:visit_call_now' visit_id=visit.id phase='post' %}">
                {% csrf_token %}
                <button type="submit" class="btn btn-secondary" style="width:100%;justify-content:center;">Run post-call</button>
            </form>
        </div>
```

The new Run AI call card sits in the right rail (`.detail-side`) immediately after the Manager Notes card.

**Step 3: Verify**

```bash
python manage.py check
wc -l static/css/screens.css
```

Expected: check passes; `screens.css` line count grew by ~35.

DO NOT commit.

---

## Task 6: `seed_demo` management command

**Files:**
- Create: `voice/management/commands/seed_demo.py`

**Step 1: Verify the management directory exists**

```bash
ls voice/management/commands/
```

Expected: list includes existing commands like `detect_ngrok.py` etc.

**Step 2: Create the new file**

Write `voice/management/commands/seed_demo.py` with exact content:

```python
"""
Demo data seed command.

Wipes and re-creates 3 demo sales agents + 3 clients + 3 visits scheduled on
the target date (default: today). Designed for tomorrow's live-calls demo.

Usage:
    python manage.py seed_demo
    python manage.py seed_demo --date 2026-05-28
"""

from datetime import date as date_cls, datetime, time, timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from voice.models import Client, User, Visit
from voice.constants import VisitStatus


class Command(BaseCommand):
    help = "Seed 3 demo agents + 3 clients + 3 visits for the live-calls demo."

    def add_arguments(self, parser):
        parser.add_argument(
            '--date',
            type=str,
            default=None,
            help='Date for the demo visits (YYYY-MM-DD). Defaults to today.',
        )

    def handle(self, *args, **opts):
        if opts['date']:
            target_date = date_cls.fromisoformat(opts['date'])
        else:
            target_date = timezone.now().date()

        # Wipe existing seeded demo data (idempotent)
        Visit.objects.filter(client__crm_id__startswith='DEMO-').delete()
        Client.objects.filter(crm_id__startswith='DEMO-').delete()
        User.objects.filter(username__startswith='demo_').delete()

        # Create 3 sales agents (user fills in phone via admin)
        AGENTS = [
            ('demo_alex',   'Alex',   'Chen'),
            ('demo_robyn',  'Robyn',  'Carter'),
            ('demo_marcus', 'Marcus', 'Lee'),
        ]
        agents = []
        for username, first, last in AGENTS:
            agent = User.objects.create(
                username=username,
                first_name=first,
                last_name=last,
                email=f"{username}@demo.local",
                is_sales_agent=True,
            )
            agent.set_password('demo')
            agent.save()
            agents.append(agent)

        # Create 3 clients
        CLIENTS = [
            ('Acme Corporation',    'SaaS / B2B'),
            ('Quorum Industries',   'Manufacturing'),
            ('Clearwater Holdings', 'Financial services'),
        ]
        clients = []
        for i, (name, industry) in enumerate(CLIENTS, start=1):
            client = Client.objects.create(
                crm_id=f'DEMO-{i:03d}',
                name=name,
                industry=industry,
                domain=f"{name.lower().replace(' ', '')}.com",
            )
            clients.append(client)

        # Create 3 visits — one per agent, paired with a client; scheduled on target_date
        tz = timezone.get_current_timezone()
        for i, (agent, client) in enumerate(zip(agents, clients), start=1):
            start = datetime.combine(target_date, time(10 + i, 0)).replace(tzinfo=tz)
            end = start + timedelta(hours=1)
            visit = Visit.objects.create(
                agent=agent,
                client=client,
                title=f"{client.name} – Q3 Planning",
                start_time=start,
                end_time=end,
                status=VisitStatus.PLANNED,
            )
            self.stdout.write(f"Visit {visit.id}: /manager/visits/{visit.id}/")

        self.stdout.write(self.style.SUCCESS(f'Demo data seeded for {target_date}.'))
        self.stdout.write('Next steps:')
        self.stdout.write('  1. Set phone numbers for demo_alex, demo_robyn, demo_marcus in /admin/')
        self.stdout.write('  2. Update ELEVENLABS_AGENT_ID env var to new agent ID')
        self.stdout.write('  3. Open each visit URL above and paste pre/post prompts')
        self.stdout.write('  4. Click "Run pre-call" / "Run post-call" on demo day')
```

**Step 3: Verify**

```bash
python manage.py help seed_demo
```

Expected: prints the command's `--help` output (no errors).

DO NOT actually run `seed_demo` here — that wipes data. The user will run it themselves when ready.

DO NOT commit.

---

## Task 7: Smoke verification

**Files:** none modified.

**Step 1: Confirm `manage.py check` passes**

```bash
python manage.py check
```

Expected: `System check identified no issues (0 silenced).`

**Step 2: Confirm URL reverses**

```bash
python -c "from django.urls import reverse; print(reverse('voice:visit_call_now', kwargs={'visit_id': 1, 'phase': 'pre'}))"
python -c "from django.urls import reverse; print(reverse('voice:visit_call_now', kwargs={'visit_id': 1, 'phase': 'post'}))"
```

Expected: both print `/manager/visits/1/call/pre/` and `/manager/visits/1/call/post/`.

**Step 3: Confirm form fields**

```bash
python -c "from voice.forms import VisitManagerNotesForm; print(VisitManagerNotesForm.Meta.fields)"
```

Expected: `['manager_notes', 'methodology', 'pre_call_prompt', 'post_call_prompt']`.

**Step 4: Confirm trigger function importable**

```bash
python -c "from voice.services.elevenlabs import trigger_visit_call; print('OK')"
```

Expected: `OK`.

**Step 5: Confirm seed_demo command available**

```bash
python manage.py help seed_demo | head -3
```

Expected: shows command help.

DO NOT commit.

---

## Task 8: Branch + commit

**Files:** none staged yet.

**Step 1: Check what's changed**

```bash
git status --short
```

**Step 2: Branch off `settings-screen`**

```bash
git rev-parse --abbrev-ref HEAD
```

If currently on `settings-screen`:

```bash
git checkout -b demo-live-calls
```

**Step 3: Stage only this pass's files**

```bash
git add voice/services/elevenlabs.py \
        voice/views.py \
        voice/urls.py \
        voice/webhook_views.py \
        voice/forms.py \
        voice/templates/voice/manager/visit_detail.html \
        static/css/screens.css \
        voice/management/commands/seed_demo.py \
        docs/superpowers/plans/2026-05-26-demo-live-calls.md
```

Verify with `git status --short` that only these files are staged.

**Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
Demo live calls: visit-aware EL trigger + Call Now button + seed_demo

- voice/services/elevenlabs.py: new trigger_visit_call(visit, phase)
  that reads visit.pre_call_prompt or visit.post_call_prompt verbatim,
  agent phone from visit.agent.phone_number, EL agent_id from settings,
  creates CallAttempt(visit=visit, meeting=None), posts to EL outbound-call
  endpoint, returns {success, call_id, error}.
- voice/urls.py + voice/views.py: VisitCallNowView at
  /manager/visits/<id>/call/<phase>/ (POST only). Calls trigger_visit_call,
  flashes success or error, redirects to visit detail.
- voice/webhook_views.py: guard call_attempt.meeting against None so
  visit-linked CallAttempts (new flow) don't crash the post-call webhook.
  Transcript / summary / recording_url still get saved to the CallAttempt;
  legacy meeting-fan-out (Pipedrive sync, -30 retry) is skipped when
  meeting is None.
- voice/forms.py: VisitManagerNotesForm extended with pre_call_prompt and
  post_call_prompt textareas.
- voice/templates/voice/manager/visit_detail.html: two <details>-collapsed
  prompt textareas inside the Manager Notes form (closed by default to
  keep the prompt text off-screen during the live demo). New "Run AI call"
  card in the right rail with Run pre-call and Run post-call buttons.
- static/css/screens.css: ~35 lines for .prompt-accordion styling.
- voice/management/commands/seed_demo.py: --date YYYY-MM-DD argument,
  wipes + creates 3 demo agents / 3 clients / 3 visits scheduled at
  11:00, 12:00, 13:00 on the target date. Prints visit URLs + next-steps.

Demo runbook in docs/superpowers/specs/2026-05-26-demo-live-calls-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)" && git log --oneline -5
```

Expected: one new commit at the top of branch `demo-live-calls`.

---

## Out of scope

- Real-time UI updates while call is in progress (no websockets)
- Per-user EL agent IDs (single shared agent via env var)
- Placeholder interpolation in prompts (sent verbatim)
- Live prompt generation from methodology/visit context
- Cleaner "demo mode" indicator / toggle
- Automated tests

## Rollback

`git revert` of the commit from Task 8. No database migrations, no service changes, no env changes — just code revert and re-run `seed_demo` after if needed.
