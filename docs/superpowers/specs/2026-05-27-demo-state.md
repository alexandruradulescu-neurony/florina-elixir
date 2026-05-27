# Demo State — 2026-05-27 (snapshot before compaction)

This file captures everything needed to continue working on the live-calls demo after a context compaction.

## Demo target

- **Date:** 2026-05-28 (tomorrow)
- **Three sales agents, three visits, six potential calls** (one pre + one post per visit), all firing real EL outbound calls.
- **Visits scheduled at 11:00, 12:00, 13:00 on 2026-05-28.**

## Current branch

`demo-live-calls` (off `settings-screen` → `management-screens` → `manager-screens` → `claude-design-foundation` → `main`).

## Stack state

| Service | Where | Notes |
|---|---|---|
| Django dev server | `python manage.py runserver 0.0.0.0:8007` | Port **8007** (was 8003 originally) |
| ngrok | `ngrok http --url=sales-assist.ngrok.app 8007` | Points at port 8007 |
| EL webhook URL | `https://sales-assist.ngrok.app/webhooks/elevenlabs/` | Configured in EL dashboard |
| ANTHROPIC_API_KEY | set in `.env` | Claude post-call analysis |
| ELEVENLABS_API_KEY | set in `.env` | EL outbound calls |
| ELEVENLABS_AGENT_ID | set in `.env` | Single EL AI persona (new one with overrides allowed) |
| ELEVENLABS_PHONE_NUMBER_ID | set in `.env` | Provisioned in EL dashboard |
| ELEVENLABS_WEBHOOK_SECRET | set in `.env` | Stashed; not yet validated in code |

## Demo data

Run `python manage.py seed_demo --date 2026-05-28` to create:

| Username | Name | Phone |
|---|---|---|
| demo_andrei | Andrei Popescu | +40722322358 |
| demo_mihai | Mihai Ionescu | +40722322358 |
| demo_vlad | Vlad Marin | +40722322358 |

(All three share the same phone number — they all ring the demo handset.)

| Visit ID | Client | Industry | Agent |
|---|---|---|---|
| 36 | Acme Corporation | SaaS / B2B | Andrei Popescu |
| 37 | Quorum Industries | Manufacturing | Mihai Ionescu |
| 38 | Clearwater Holdings | Financial services | Vlad Marin |

(IDs may differ on a re-seed — check the seed_demo output.)

## Architecture: how a call fires end-to-end

1. **Pre-demo:** open each visit `/manager/visits/<id>/`, expand 4 accordions in the right-rail Manager Notes form:
   - Pre-call prompt → paste system prompt for the pre-call
   - Pre-call first message → paste the AI's opening line for the pre-call
   - Post-call prompt → paste system prompt the AI uses to debrief the agent
   - Post-call first message → paste the AI's opening line for the debrief
   - Click Save.

2. **Click Run pre-call / Run post-call** in the right rail "Run AI call" card.

3. **Backend path:**
   - POST `/manager/visits/<id>/call/<pre|post>/` → `VisitCallNowView` → `trigger_visit_call(visit, phase)`
   - `trigger_visit_call` reads `visit.pre_call_prompt` (or post) and `visit.pre_call_first_message` (or post), agent's phone, env vars, and posts to `https://api.elevenlabs.io/v1/convai/twilio/outbound-call`
   - Creates `CallAttempt(visit=visit, meeting=None, phase=PRE_MEETING|POST_MEETING, status=INITIATED)`
   - On 200, stores `external_call_id = conversation_id`, status → IN_PROGRESS

4. **EL places the call,** AI talks to the sales agent.

5. **EL fires `post_call_transcription` webhook** to `/webhooks/elevenlabs/`:
   - Handler looks up CallAttempt by `external_call_id`
   - Saves `transcript`, `summary` (EL's), `summary_title`, `recording_url`, `duration_seconds`, `status`
   - Skips legacy meeting fan-out when `meeting is None`
   - **If `phase == POST_MEETING` and transcript non-empty:** synchronously calls `analyze_post_call(transcript, visit.post_call_prompt, visit_context)` → Claude returns structured JSON → saved to `CallAttempt.analysis`

6. **Visit Detail page** reads `analysis` from the latest post-call CallAttempt via `placeholders.visit_detail_extras`. If present, ministats become real and new sections render: No-go banner (conditional), Objective attainment, Actionables, Recommendations, Next Best Actions, Objections & Risks.

## Model changes

- `CallAttempt.analysis = JSONField(default=dict, blank=True)` — Claude's structured output (migration `0013_callattempt_analysis`)
- `Visit.pre_call_first_message = TextField(blank=True, default='')` (migration `0012_visit_post_call_first_message_and_more`)
- `Visit.post_call_first_message = TextField(blank=True, default='')` (same migration)

## Claude analysis schema (returned by `analyze_post_call`)

```
{
  summary: str,
  objective_attained: "attained" | "partial" | "missed",
  objective_assessment: str,
  actionables: [{owner, action, due}],
  recommendations: [str],
  next_best_actions: [{action, rationale, timing}],
  no_go: {is_no_go, reason, salvage_path},
  sentiment: "positive"|"neutral"|"negative"|"mixed",
  sentiment_score: int (0-100),
  talk_ratio: {agent, client},
  objections_raised: [str],
  objections_handled: [str],
  champion_strength: "weak"|"moderate"|"strong"|"champion",
  risks: [str]
}
```

Implemented in `voice/services/llm.py::analyze_post_call(transcript, post_call_prompt, visit_context)`. Returns the dict or `None` on failure (failure leaves analysis empty, ministats fall back to placeholders).

## Important files modified for the demo

- `voice/models.py` — added `analysis` field on CallAttempt, `pre_call_first_message`/`post_call_first_message` on Visit
- `voice/services/elevenlabs.py` — `trigger_visit_call(visit, phase)` function appended at end; reads first_message from the visit and sends it in the EL payload
- `voice/services/llm.py` — `analyze_post_call` function appended
- `voice/webhook_views.py` — guarded `call_attempt.meeting` against None; added synchronous Claude analysis on POST-phase transcripts
- `voice/forms.py` — VisitManagerNotesForm extended with `pre_call_first_message` and `post_call_first_message` (and existing `pre_call_prompt`/`post_call_prompt`)
- `voice/views.py` — `VisitCallNowView` (POST /manager/visits/<id>/call/<phase>/)
- `voice/urls.py` — `voice:visit_call_now` URL
- `voice/templates/voice/manager/visit_detail.html` — 4 accordions (one per prompt/first_message), Run AI Call card, new analysis sections (No-go, Objective, Actionables, Recommendations, NBA, Objections & Risks)
- `voice/management/commands/seed_demo.py` — Romanian names, --date argument
- `static/css/screens.css` — calendar primitives, form chrome, accordion styling, analysis section styling (~2300 lines total)
- `voice/templates/voice/base.html` — sidebar Agents row active-state extended to agent_detail

## Known gaps / explicit out-of-scope for tomorrow

- Real-time UI updates while call is in progress (no websockets; refresh to see updates)
- Per-user EL agent IDs (single shared agent via env var)
- Live prompt generation from methodology/visit context (prompts pasted verbatim)
- EL webhook HMAC signature validation (secret stored in env var but not validated; webhook is public on ngrok URL)
- Drag-and-drop reschedule on calendar
- Click-to-create on empty time slots
- Per-agent customization beyond phone number
- Pipedrive / Google Calendar live sync (still uses legacy Meeting model paths, untouched)

## Demo runbook (concise)

1. `python manage.py seed_demo --date 2026-05-28` (already done; re-run if data lost)
2. In `/admin/` confirm phone numbers on demo_andrei, demo_mihai, demo_vlad (all `+40722322358`)
3. Confirm `.env` has ELEVENLABS_API_KEY, ELEVENLABS_AGENT_ID, ELEVENLABS_PHONE_NUMBER_ID, ANTHROPIC_API_KEY all set
4. Confirm EL dashboard has overrides enabled (System Prompt + First Message) on the agent matching `ELEVENLABS_AGENT_ID`
5. Confirm EL webhook URL configured to `https://sales-assist.ngrok.app/webhooks/elevenlabs/`
6. Confirm server running on 8007 and ngrok on 8007
7. Open each `/manager/visits/<id>/`, paste 4 prompts/messages per visit, click Save
8. Smoke test: click "Run pre-call" on visit 36 → demo handset rings → AI talks → hang up
9. Click "Run post-call" → AI debriefs → hang up → refresh Visit Detail in 10-15s → see Claude analysis sections populate

## What's been built since the design system foundation

In order on the branch chain:
- Foundation (`claude-design-foundation`): tokens, icons, fonts, shell, base.html, 3 partials
- Manager screens (`manager-screens`): Dashboard, Visits list, Visit Detail
- Management screens (`management-screens`): Agents list/detail/form, Clients list/detail, Methodologies list/form
- Calendar (`calendar-screen`): Week + Day views with `chip-row`/pre/post markers
- Settings (`settings-screen`): restyle of global settings form
- Demo live calls (`demo-live-calls`): trigger_visit_call + Call Now button + seed + Claude post-call analysis + accordion UI for prompts/first_messages
