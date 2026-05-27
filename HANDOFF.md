# Sales Assistant — Handoff Guide

This document walks a new engineer from `git clone` to a fully working demo
in under 10 minutes. The demo is a Romanian-language sales coach: an AI named
**Florina** that calls sales agents before and after their client meetings,
verifies preparation, debriefs results, and writes structured CRM notes via
Claude.

The branch with everything wired up is **`demo-live-calls`**.

---

## What you'll have after setup

- **Manager dashboard** with 3 demo sales agents and 3 upcoming visits
- **Calendar** (week + day views) with pre/post-call state markers
- **Visit Detail** for each visit, with Romanian system prompts, expandable
  transcripts, structured Claude analysis (objective attainment, actionables,
  NBA, risks, pre↔post consistency check), and a "Marchează vizita ca finalizată"
  workflow
- **Live ElevenLabs voice calls** triggered from the UI, recorded, transcribed,
  and analyzed end-to-end
- **Romanian content** seeded on the 3 demo visits (Domus Imobiliare,
  Farmaciile Vitalis, Logix Transport)

---

## Prerequisites

| Tool | Version | Why |
|---|---|---|
| Python | 3.11+ | Django backend |
| PostgreSQL | 14+ | Database |
| ngrok | latest | Tunnels the ElevenLabs webhook to your local server |
| ElevenLabs account | Conversational AI plan | Outbound voice calls |
| Anthropic API key | any tier | Post-call analysis + Romanian summaries |

---

## Step-by-step setup

### 1. Clone and install

```bash
git clone <repo-url> proj-salesassistant
cd proj-salesassistant
git checkout demo-live-calls

python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 2. Database

```bash
# Create the DB and user (adjust password to your taste — must match .env)
createdb salesassistant
createuser django_user --pwprompt
psql -c "GRANT ALL PRIVILEGES ON DATABASE salesassistant TO django_user;"
psql -d salesassistant -c "GRANT ALL ON SCHEMA public TO django_user;"
```

### 3. Environment file

```bash
cp .env.example .env
```

Fill in the values:

- **DB_PASSWORD** — the password you set for `django_user`
- **ANTHROPIC_API_KEY** — your Claude key (get one at https://console.anthropic.com)
- **ELEVENLABS_*** — set up an agent + phone number in the ElevenLabs dashboard
  (see "ElevenLabs setup" below)
- **NGROK_URL** — only change if you have your own reserved subdomain

The project owner will share the actual demo `.env` with the live keys
separately (don't commit it).

### 4. Migrations + demo seed

```bash
python manage.py migrate
python manage.py setup_demo
```

`setup_demo` creates everything in one shot:

- **admin** superuser (password `admin123`)
- 3 demo sales agents: `demo_andrei`, `demo_mihai`, `demo_vlad` (password `demo`)
- All 3 agents share phone **+40722322358** (the demo handset)
- 3 Romanian clients: Domus Imobiliare (nou), Farmaciile Vitalis (existent),
  Logix Transport (existent)
- 3 visits on **2026-05-28** at 11:00, 12:00, 13:00 — one per agent
- 3 Methodology rows linked to the visits
- All 12 Romanian prompts (pre + first message + post + first message per visit)

Options:
```bash
python manage.py setup_demo --date 2026-06-15      # different demo date
python manage.py setup_demo --admin-password mypw  # different admin password
python manage.py setup_demo --skip-admin           # keep existing admin
```

The command is **idempotent** — safe to re-run; it overwrites demo content
in place via `update_or_create`, doesn't touch unrelated data.

### 5. ngrok + ElevenLabs webhook

Start the tunnel:

```bash
ngrok http --url=sales-assist.ngrok.app 8007
```

If you don't have that reserved subdomain, drop the `--url` flag and ngrok
will give you a random one. Then update the webhook URL in the ElevenLabs
dashboard:

```
ElevenLabs → Conversational AI → Webhooks
Webhook URL: https://<your-ngrok-url>/webhooks/elevenlabs/
Type: post_call_transcription
```

Also update `NGROK_URL` and `ALLOWED_HOSTS` / `CSRF_TRUSTED_ORIGINS` in `.env`
to match.

### 6. Start the server

```bash
python manage.py runserver 0.0.0.0:8007
```

Open http://localhost:8007/dashboard/admin/ and log in with `admin` / `admin123`.

---

## ElevenLabs setup (one-time)

1. **Create an agent** at https://elevenlabs.io/app/conversational-ai
2. **Enable overrides** so the per-visit prompt + first-message can replace
   the agent defaults:
   - Agent → Security tab → Overrides
   - Enable both **System Prompt** and **First Message**
3. **Provision a phone number** — Conversational AI → Phone Numbers. Pick a
   number that can call Romania (+40 prefix).
4. **Copy the IDs** into `.env`:
   - `ELEVENLABS_AGENT_ID` from the agent page
   - `ELEVENLABS_API_KEY` from the API keys page
   - `ELEVENLABS_PHONE_NUMBER_ID` from the phone numbers page
5. **Configure the webhook** as described in step 5 above.

---

## Login credentials

| Username | Password | Role | Phone |
|---|---|---|---|
| `admin` | `admin123` | Superuser / sales manager | — |
| `demo_andrei` | `demo` | Sales agent (Andrei Popescu) | +40722322358 |
| `demo_mihai` | `demo` | Sales agent (Mihai Ionescu) | +40722322358 |
| `demo_vlad` | `demo` | Sales agent (Vlad Marin) | +40722322358 |

All 3 agents share the same phone number — calls will ring the demo handset
regardless of which agent triggered them.

---

## Key URLs

| URL | What it is |
|---|---|
| `/` | Role-aware landing (redirects to manager dashboard for admin) |
| `/admin/` | Django admin |
| `/dashboard/admin/` | Manager dashboard (Recent summaries, Today's timeline, Agent readiness, This week, Next visit) |
| `/manager/visits/` | Visits list — open from here to find the 3 demo visits |
| `/manager/calendar/` | Week + Day calendar with pre/post markers |
| `/manager/clients/` | Clients list |
| `/manager/agents/` | Agents list |
| `/manager/methodologies/` | Methodologies list |
| `/manager/settings/` | Global settings |

---

> ℹ️ Visit IDs auto-increment, so they vary across fresh setups. The
> `setup_demo` command prints the current IDs at the end of its output;
> alternatively just open `/manager/visits/` and click into them.

The 3 demo cases are always:
- **Domus Imobiliare** (Andrei, client NOU, construction materials, 11:00)
- **Farmaciile Vitalis** (Mihai, client existent, pharma, 12:00)
- **Logix Transport** (Vlad, client existent, HR services, 13:00)

## How to run a demo call

1. Open `/manager/visits/` and click the Domus Imobiliare row
2. In the right rail, scroll to the **Run AI Call** card
3. Click **Run pre-call** — the demo handset rings within ~10 seconds
4. Talk to Florina, hang up when done
5. Refresh in 10-15 seconds → the pre-call panel populates with Romanian summary,
   transcript expandable, stepper advances to "Pre-Call ✓"
6. (optionally simulate a real meeting, then) click **Run post-call**
7. Refresh → Romanian summary + structured analysis sections render:
   - Atingere obiectiv (pill: Atins / Parțial / Ratat)
   - Acțiuni de făcut
   - Recomandări pentru agent
   - Următorii pași pentru deal
   - Obiecții și riscuri
   - Verificare consistență pre↔post (badge: Consistent or N discrepanțe)
   - Metrici (sentiment, talk ratio, sprijin client)

---

## Placeholder tokens in prompts

Each prompt in DB uses `{tokens}` that are substituted at runtime by
`voice/services/elevenlabs.py::format_prompt_for_visit`:

| Token | Resolves to |
|---|---|
| `{agent_first_name}` | Visit.agent.first_name |
| `{agent_full_name}` | Visit.agent.get_full_name() |
| `{agent_phone}` | Visit.agent.phone_number |
| `{client_name}` | Visit.client.name |
| `{client_status}` | "client nou" / "client existent" |
| `{client_status_upper}` | "CLIENT NOU" / "CLIENT EXISTENT" |
| `{client_industry}` | Visit.client.industry |
| `{visit_date}` | "28 mai 2026" (Romanian) |
| `{visit_time}` | "11:00" |
| `{visit_duration}` | "60 de minute" |
| `{visit_title}` | Visit.title |
| `{methodology_name}` | Visit.methodology.name |
| `{manager_notes}` | Visit.manager_notes |
| `{pre_call_summary}` | Latest pre-call's Romanian summary (post-call only) |

Add new tokens in `format_prompt_for_visit`'s `tokens` dict — no other change
needed for them to work in any prompt.

---

## Project structure (where to look)

```
voice/
├── models.py                 # Visit, Client, CallAttempt, Methodology, User
├── constants.py              # Enums: ClientStatus, VisitStatus, CallStatus, CallPhase
├── views.py                  # SuperuserDashboardView, VisitDetailView, VisitCallNowView, etc.
├── urls.py                   # /manager/visits/<id>/call/<phase>/, /status/<status>/, etc.
├── placeholders.py           # All template "extras" helpers (no fake data — real DB-driven)
├── selectors.py              # Read-only DB queries
├── webhook_views.py          # ElevenLabsWebhookView — receives transcripts, runs Claude
├── services/
│   ├── elevenlabs.py         # trigger_visit_call + format_prompt_for_visit
│   └── llm.py                # _resolve_anthropic_key, analyze_post_call,
│                             #   summarize_call_transcript_ro, _call_claude
├── forms.py                  # VisitManagerNotesForm (with date/time/duration pickers)
├── templates/voice/manager/  # All HTML templates
│   ├── dashboard.html
│   ├── visit_detail.html     # the big one — left col + right rail
│   ├── visit_calendar.html
│   └── ...
└── management/commands/
    ├── setup_demo.py         # ★ The one-shot bootstrap
    ├── seed_demo.py          # Creates agents + clients + visits
    └── seed_demo_content.py  # Renames clients to Romanian + statuses + methodologies + 12 prompts

static/css/screens.css        # ~2400 lines, hand-rolled (no Tailwind)
docs/superpowers/specs/2026-05-27-demo-state.md  # Full demo state snapshot
```

---

## Modifying the demo content

The 12 Romanian prompts + 3 methodologies + client names + statuses all live
in **`voice/management/commands/seed_demo_content.py`** as Python triple-quoted
strings. To change one:

1. Edit the relevant constant in the file (e.g. `V36_PRE_PROMPT`,
   `METHODOLOGY_FARMA`, `VISIT_CONTENT[0]['client_new_name']`)
2. Re-run: `python manage.py seed_demo_content`
3. Refresh the page

The command is idempotent — it overwrites the matching DB rows in place.

Alternatively, you can edit prompts directly in the UI via the **Manager Notes**
accordions on each Visit Detail page and click **Save**. Those changes persist
until the next `seed_demo_content` run.

---

## Troubleshooting

**"Missing env vars: ELEVENLABS_API_KEY..."** when clicking Run pre-call
→ Restart the Django server after editing `.env`. python-decouple reads `.env`
at process start.

**"Webhook returned 500" / no transcript saved**
→ Check `ngrok` is running on the right port (8007) and the URL matches what's
configured in the ElevenLabs dashboard.

**Pre-call English summary instead of Romanian**
→ Claude API call failed. Check ANTHROPIC_API_KEY is set and not an empty string
in your shell (`echo $ANTHROPIC_API_KEY` should be empty — if it prints a value,
unset it: `unset ANTHROPIC_API_KEY` and restart the server). `voice/services/llm.py`
has a fallback to read `.env` directly when `os.environ` returns empty.

**Stepper not advancing after a call**
→ The webhook auto-advances Visit.status. If it didn't fire, click the manual
button: "Marchează întâlnirea ca având loc" (after pre-call) or "Marchează
vizita ca finalizată" (after post-call) appears under the stepper.

**"No methodology" everywhere on Agents list**
→ `User.default_methodology` is unset by default. Set it via Django admin →
Users → choose agent → Default methodology dropdown.

---

## Git branches

- **`main`** — original codebase before the redesign
- **`claude-design-foundation`** — design tokens, fonts, icons, shell
- **`manager-screens`** — Dashboard, Visits list, Visit Detail
- **`management-screens`** — Agents, Clients, Methodologies
- **`calendar-screen`** — Week + Day calendar
- **`settings-screen`** — Settings form
- **`demo-live-calls`** ← this is the branch to run the demo from

---

## Contact

If you need the live demo `.env` with real ElevenLabs + Anthropic keys, ask
the project owner directly. Don't commit it.
