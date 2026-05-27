# Demo Live Calls — Implementation Spec

**Date:** 2026-05-26
**Status:** Approved
**Builds on:** branch `settings-screen`
**Demo deadline:** Tomorrow

## Goal

Wire the existing ElevenLabs integration to the new Visit model so we can trigger real outbound EL voice calls from the Visit Detail page during tomorrow's demo. Three sales agents, three visits, six calls total (one pre + one post per visit). Calls go to the sales agent's phone; the AI agent in EL reads a prompt that we paste in pre-demo.

## Locked decisions

| # | Decision |
|---|---|
| 1 | One shared EL agent (new `ELEVENLABS_AGENT_ID` value user will provide); no per-user agent_id field |
| 2 | Prompts are pasted verbatim by the user pre-demo into the Visit Detail manager-notes form, stored on `Visit.pre_call_prompt` / `Visit.post_call_prompt`, sent to EL with no placeholder interpolation |
| 3 | Prompt textareas live inside `<details>` collapsible sections, closed by default, so prompt text isn't visible on screen during the live demo |
| 4 | Phone numbers added manually by the user via Django admin after `seed_demo` runs |
| 5 | EL agent and webhook URL configured by the user in the EL dashboard in parallel; our code just needs the `ELEVENLABS_AGENT_ID` env var set before demo |
| 6 | Webhook handler updates the CallAttempt regardless of whether `meeting` or `visit` FK is set; the legacy meeting-bump logic is guarded so it skips when `meeting is None` |
| 7 | No migration for User model — single shared EL agent ID via env var |

## File layout

### Create
- `voice/management/commands/seed_demo.py` — wipes + creates 3 agents, 3 clients, 3 visits
- (No new templates, no new partials)

### Modify
- `voice/services/elevenlabs.py` — add `trigger_visit_call(visit, phase)` function (~80 lines)
- `voice/views.py` — add `VisitCallNowView` (~30 lines)
- `voice/urls.py` — add 1 URL pattern for the call trigger
- `voice/forms.py` — extend `VisitManagerNotesForm` to include `pre_call_prompt` and `post_call_prompt` textareas
- `voice/templates/voice/manager/visit_detail.html` — add Call Now buttons (right rail) and `<details>` accordions for pre/post prompt textareas in the manager-notes form
- `voice/webhook_views.py` — add a guard so the webhook handler doesn't crash on `CallAttempt.meeting is None`

### Don't touch
- The existing `trigger_agent_call()` function (legacy meeting-keyed path stays for backward compatibility, even though we won't use it for the demo)
- `voice/models.py` (no schema changes)
- Other screens

## Per-component design

### `trigger_visit_call(visit, phase)` in `voice/services/elevenlabs.py`

```python
def trigger_visit_call(visit, phase):
    """Initiate an EL outbound call for a Visit and phase ('pre' or 'post').

    Reads the pre-rendered prompt directly from visit.pre_call_prompt /
    post_call_prompt. Picks the agent's phone from visit.agent.phone_number.
    Uses settings.ELEVENLABS_AGENT_ID as the shared EL agent.

    Returns {'success': bool, 'call_id': str|None, 'error': str|None}.
    Creates a CallAttempt(visit=visit, phase=phase, ...) row on success
    and sets external_call_id from the EL response."""
```

Implementation outline:
1. Validate phase ∈ {`'pre'`, `'post'`}; map to `CallPhase` enum.
2. Pick prompt: `visit.pre_call_prompt` or `visit.post_call_prompt`. If blank, return error "Prompt not set — paste it on the Visit Detail page first."
3. Validate `visit.agent.phone_number`; format to E.164 via existing `format_phone_number()`.
4. Validate env vars (`ELEVENLABS_API_KEY`, `ELEVENLABS_AGENT_ID`, `ELEVENLABS_PHONE_NUMBER_ID`).
5. Create `CallAttempt(visit=visit, meeting=None, phase=..., status=INITIATED, executed_at=now)`.
6. POST to `https://api.elevenlabs.io/v1/convai/twilio/outbound-call` with payload:
   ```python
   {
       "agent_id": settings.ELEVENLABS_AGENT_ID,
       "agent_phone_number_id": settings.ELEVENLABS_PHONE_NUMBER_ID,
       "to_number": formatted_phone,
       "conversation_initiation_client_data": {
           "conversation_config_override": {
               "agent": {
                   "prompt": {"prompt": prompt_text}
               }
           }
       }
   }
   ```
7. On 200: extract `conversation_id` (or `call_id`/`id`/`call_sid`), set `call_attempt.external_call_id`, status → `IN_PROGRESS`, save. Return `{'success': True, 'call_id': ..., 'error': None}`.
8. On non-200: status → `FAILED`, save. Return `{'success': False, 'call_id': None, 'error': error_msg}`.

### `VisitCallNowView` in `voice/views.py`

```python
class VisitCallNowView(SuperuserRequiredMixin, View):
    def post(self, request, visit_id, phase):
        visit = get_object_or_404(Visit, id=visit_id)
        if phase not in ('pre', 'post'):
            messages.error(request, "Invalid phase.")
            return redirect('voice:visit_detail', visit_id=visit_id)
        result = trigger_visit_call(visit, phase)
        if result['success']:
            messages.success(request, f"{phase.title()}-call initiated. Call ID: {result['call_id']}")
        else:
            messages.error(request, f"Call failed: {result['error']}")
        return redirect('voice:visit_detail', visit_id=visit_id)
```

URL: `path('manager/visits/<int:visit_id>/call/<str:phase>/', views.VisitCallNowView.as_view(), name='visit_call_now')`.

### `VisitManagerNotesForm` extension in `voice/forms.py`

Add `pre_call_prompt` and `post_call_prompt` as `forms.CharField(widget=forms.Textarea, required=False)` fields. Existing `Meta.fields` list expanded.

### Visit Detail template additions

In the manager-notes form (right rail), after the existing textarea:

```django
<details class="prompt-accordion">
    <summary>Pre-call prompt</summary>
    <textarea name="pre_call_prompt" ...>{{ form.pre_call_prompt.value|default:'' }}</textarea>
</details>
<details class="prompt-accordion">
    <summary>Post-call prompt</summary>
    <textarea name="post_call_prompt" ...>{{ form.post_call_prompt.value|default:'' }}</textarea>
</details>
```

Plus minimal CSS in screens.css (~15 lines) for `.prompt-accordion` styling: cursor pointer summary, subtle background.

Also in the right rail, ADD a new card with the two Call Now buttons:

```django
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

### Webhook guard

In `voice/webhook_views.py`, find any code that does `call_attempt.meeting.something` and wrap in `if call_attempt.meeting:`. Specifically:
- The bump of `meeting.is_pre_call_completed` / `is_post_call_completed`
- The Pipedrive sync that uses `meeting`
- Any logging that does `call_attempt.meeting.agent`

For visit-linked calls, transcript/summary/recording_url still get saved to the CallAttempt row — we just skip the legacy meeting fan-out.

### `seed_demo` management command

Accepts an optional `--date YYYY-MM-DD` argument. Defaults to the date the command is run. Visits are scheduled at 11:00, 12:00, and 13:00 local time on the chosen date so they appear in today's Dashboard / Visits / Calendar default views.

```python
from datetime import date as date_cls, datetime, time, timedelta
from django.core.management.base import BaseCommand
from django.utils import timezone

class Command(BaseCommand):
    help = "Seed 3 demo agents + 3 clients + 3 visits for the live-calls demo."

    def add_arguments(self, parser):
        parser.add_argument('--date', type=str, default=None,
                            help='Date for the demo visits (YYYY-MM-DD). Defaults to today.')

    def handle(self, *args, **opts):
        # Resolve target date
        if opts['date']:
            target_date = date_cls.fromisoformat(opts['date'])
        else:
            target_date = timezone.now().date()

        # Wipe existing seeded demo data (idempotent — safe to re-run)
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

**Note on date:** because Dashboard, Visits, and Calendar default to "today", run the seed command the morning of the demo, or pass `--date` matching the demo day. Re-running the command wipes and re-creates demo data idempotently.

## Demo runbook (for tomorrow)

1. **Pre-demo (today/tonight):**
   - Run `python manage.py seed_demo`
   - In `/admin/`, edit the 3 demo users to add their phone numbers
   - In `.env`, update `ELEVENLABS_AGENT_ID` to the new EL agent ID you created
   - Visit each `/manager/visits/<id>/` URL, expand the Pre-call prompt accordion, paste the prompt, then expand Post-call prompt, paste the prompt, click Save
   - Verify EL webhook URL is configured in EL dashboard to point at your ngrok URL
   - Smoke test: click "Run pre-call" on one of the visits, verify the phone rings, hang up

2. **Live demo:**
   - Open `/dashboard/admin/` — show the dashboard
   - Click a visit → Visit Detail
   - Click "Run pre-call" → phone rings, AI talks, you can answer/listen
   - (Optionally) refresh Visit Detail post-call to show transcript/summary appearing
   - Repeat for post-call

## End-to-end visibility checklist

After running `seed_demo` (with `--date` matching the demo day), verify that the seeded data shows up everywhere it should. This works because all three screens default to "today" and the seed schedules visits at 11:00, 12:00, 13:00 on the target date. No new code is needed for this — the existing views already pull from `Visit`, `User(is_sales_agent=True)`, and `Client`.

| Screen | What you should see |
|---|---|
| `/dashboard/admin/` — **Needs Attention** | Possibly populated with placeholder action items derived from the 3 demo visits |
| `/dashboard/admin/` — **Stat row** | `Active`, `Complete today`, `Pre-call done`, `Post-call done` all reflect the 3 demo visits |
| `/dashboard/admin/` — **Agent Readiness** | One card per demo agent (Alex Chen, Robyn Carter, Marcus Lee), each showing the agent's avatar, methodology label ("No methodology" if you haven't assigned one), live/ready/idle pill, 8-tile bar-stack with the demo visit, success rate |
| `/dashboard/admin/` — **Today's Timeline** | 3 rows, one per demo visit, with time (11:00, 12:00, 13:00), agent avatar, client name + industry, status pill, kebab → visit detail |
| `/manager/visits/` | Stat row reflects 3 visits; table shows 3 rows; clicking the kebab → visit detail |
| `/manager/calendar/?view=week` | Today's row highlighted with "THIS WEEK" badge; today's column shows the 3 demo events stacked as cyan chips |
| `/manager/calendar/?view=day&date=<demo-date>` | Hour stream shows the 3 events at 11:00, 12:00, 13:00 buckets; mini-cal sidebar highlights today |
| `/manager/agents/` | 3 demo agents in the `.atable` with their methodology (or "—"), today's load bar, success % |
| `/manager/agents/<id>/` | Agent Detail page for each demo agent — meta card, today's load bar, recent visits table containing the demo visit |
| `/manager/clients/` | 3 demo clients (Acme, Quorum, Clearwater) with industries and 1 visit each |
| `/manager/clients/<id>/` | Client Detail page showing the single demo visit in visit history |
| `/manager/visits/<id>/` | Visit Detail with metastrip, stepper at "Planned", Manager Notes form with the two new accordion textareas for prompts, Run AI Call card with two buttons |

If any of these screens shows empty / no demo data, the date-of-seed-vs-demo-day is the most likely culprit — re-run `seed_demo --date <demo-day>`.

## Out of scope

- Real-time UI updates while call is in progress (no websockets; user refreshes to see updates)
- Per-user EL agent IDs (single shared agent)
- Placeholder interpolation in prompts (prompts pasted verbatim)
- Live prompt generation from methodology/visit context
- Cleaner "demo mode" indicator / toggle
- Anything we don't need for the six-call demo

## Rollout

Stay uncommitted across implementation; final commit on a new branch `demo-live-calls` off `settings-screen`. Rollback is `git revert` if needed post-demo.
