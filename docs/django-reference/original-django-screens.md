# Original Django app — front-end screen reference

Source: the original Django sales-assistant (`/Users/alex/Code/proj-salesassistant`,
project `proj_mes_voice`, single app `voice`). This documents every user-facing
screen — its functionality and its fields — extracted from `voice/urls.py`,
`voice/views.py`, `voice/forms.py`, `voice/models.py`, and the templates under
`voice/templates/voice/`. Reference-only, to inform the Elixir/Phoenix port.

Two audiences: **superuser/manager** (the console) and **sales agent** (their own
schedule). Most screens are manager screens.

---

## Auth & shared

### Home — `/` (public → role redirect)
Authenticated landing page that routes by role. `HomeView` (LoginRequiredMixin)
sends superusers to the manager dashboard and sales agents to their schedule; if
neither, it shows a simple welcome card. The card greets the user by full
name/username and renders role-appropriate buttons plus log out.

No editable fields. Buttons: "Go to Dashboard" (superuser → `superuser_dashboard`),
"Go to My Schedule" (agent → `sales_agent_dashboard`), "Log out".

### Sign in — `/login/` (public)
`CustomLoginView` (extends Django `LoginView`). A "Remember me" checkbox sets a
14-day session when checked, otherwise the session expires on browser close.
Failed logins show a red error toast; the username field auto-focuses.

Fields: **username** (text, required, autocomplete username), **password**
(password, required, current-password), **remember_me** (checkbox, default off).
Submit "Sign in"; subtitle "Sales Assistant — Manager console".

### Signed out — `/logout/` (public)
`CustomLogoutView` logs out on GET or POST and renders a confirmation card. No
fields. Heading "You've been signed out" + a "Sign in again" link back to login.

---

## Agent screens

### My Schedule — `/dashboard/agent/` (agent)
The sales-agent home. `SalesAgentDashboardView` builds today's timeline
(pre-calls, meetings, post-calls), call statistics, and the next 10 upcoming
visits. The timeline is a visual component with icons and colored status badges;
pre-call rows can expose a "Listen to Recording" button when a `recording_url`
exists.

Fields/data: **Call Statistics** card — `total`, `completed`, `success_rate` (%).
**Today's Timeline** items — `time` (H:i), `type` (pre_call/meeting/post_call),
`status` (COMPLETED/NO_ANSWER/FAILED/SCHEDULED), optional recording link.
**Upcoming Visits** table — `title`, `customer` (client.name), `start_time`,
`pre_call_status` (COMPLETED/PENDING).

### Profile Settings — `/profile/` (agent)
`SalesAgentProfileView` shows read-only identity and lets the agent update their
phone number. POST validates E.164 format, normalizes, saves to the `User`, and
redirects with a success/error message.

Read-only: **username**, **email** (default "Not provided"), **is_sales_agent**
(Yes/No badge). Editable: **phone_number** (text, placeholder "+1234567890",
help "Required for receiving coaching calls. E.164 format"). Buttons "Save
Changes", "Cancel".

### Calendar Sync Status — `/calendar/status/` (agent)
`CalendarSyncStatusView` manages Google Calendar integration. It reads OAuth
credentials from the session, loads the agent's 20 most recent visits and 10
recent activity logs, and warns if the user isn't flagged as a sales agent.
Buttons connect/reconnect to Google (`google_calendar_oauth`) and trigger a
manual sync (`calendar_sync_trigger`).

Fields/data: **has_credentials** (Connected/Not Connected badge); meetings table
columns **title**, **customer** (client.name), **start_time**, **end_time**,
**pre_call_status** (Pending if PLANNED), **post_call_status** (✓ if
POST_CALL_DONE/COMPLETE); recent **activity logs** table with **level**
(ERROR/WARNING/INFO), **action**, **timestamp**.

---

## Manager — overview & operations

### Dashboard — `/dashboard/admin/` (manager)
Real-time operational overview. Shows business metrics (active/complete visits,
pre/post-call success counts), per-agent "readiness" cards (today's workload +
success rate), a "Needs Attention" list with severity, recent call summaries
with outcome chips, a weekly KPI summary, and today's timeline of all visits.
Filter buttons (Today/This week/All/At risk), a "New visit" button, and a live
"next visit" countdown pill.

Context: `visit_summary` (in_progress, complete, pre_call_done, post_call_done);
`agent_cards` (username, methodology.name, status, bars, visit_count,
success_rate, issues); `action_items` (message, type, severity, visit_id);
`weekly` (week_start/end + KPIs); `recent_summaries_with_chips`
(post_call_summary / recent_summary_text + tone chips); `todays_visits_enriched`
(pre_state/post_state, is_active); `next_visit_chip` (label, client, time).

### Visits — `/manager/visits/` (manager)
All visits for a selected date, with daily prev/next navigation. Filter by status
(All/Upcoming/Completed/Cancelled) and by agent. A summary strip shows total
today, active now (with live client names), at-risk count, and CRM-sync
completion %. Each row links to the visit detail.

Columns: start/end time; agent (name + avatar); client (name + industry);
methodology; pre/post-call completion icons; status badge
(Planned/Pre-Call/Active/Debrief/Complete); CRM sync state (colored dot).
Context: `target_date`, `group_filter`, `agent_filter`, `agents`, `summary`
(total, active_count, at_risk_count, crm_synced_count/total/pct), enriched
`visits` (pre_call_done, post_call_done, crm_state, avatar_palette).

### Visit Calendar — `/manager/calendar/` (manager)
Week and day view of visits with status + agent filters. Week view renders
visits as color-coded chips in day cells with pre/post-call state dots; day view
lists events by hour slot with a mini-month sidebar and day stats. Chips link to
the detail page.

Context: `view_mode` (week/day), `target_date`, `status_filter`, `agent_filter`,
`weeks_enriched` (days with is_today/has_events, events with time_range,
pre_state, post_state, state), `hour_buckets`, `month_grid`, `day_visit_count`.

### Visit Form — `/manager/visits/add/` and `/manager/visits/<id>/edit/` (manager)
Create/edit a visit. Uses separate date/time/duration inputs (broad browser
support) rather than a single datetime field. On create, the visit is saved as
PLANNED and auto-scheduled for pre/post-call prompts; a sidebar checklist
explains the automated workflow.

`VisitForm` fields: **agent** (select of sales agents), **client** (select),
**title** (text), **methodology** (optional override select), **manager_notes**
(textarea, pre-call instructions), **visit_date** (date), **visit_start_time**
(time, step 60), **visit_duration_minutes** (integer, 5–480).

### Visit Detail — `/manager/visits/<id>/` (manager)
The operational hub for one visit. A stepper shows lifecycle
(Planned → Pre-Call Done → In Progress → Post-Call Done → Complete) with manual
status-advance buttons. Left column: metadata, attendees, pre-call and post-call
panels (title/description/tags, optional transcript snippet, prompt
view/edit buttons), and conditional AI-analysis cards (objective attainment,
NO-GO signals, actionables, recommendations, next best actions, consistency,
objections/risks, sentiment/talk-ratio ministats). Right sidebar: manager notes +
inline schedule edit, "Run AI call" (pre/post buttons), "Regenerate prompts"
(with locked-field indicators), and client intel.

Editable (`VisitManagerNotesForm` + modals): **manager_notes**, **methodology**,
**pre_call_prompt**, **pre_call_first_message**, **post_call_prompt**,
**post_call_first_message**, **visit_date**, **visit_start_time**,
**visit_duration_minutes**. Lock flags toggled in modals:
**pre_call_prompt_locked**, **pre_call_first_message_locked**,
**post_call_prompt_locked**, **post_call_first_message_locked**. Also shows
`recent_runs` (GenerationRun: created_at, domain, triggered_by, success/error,
input/output tokens).

### Programmed Calls — `/manager/calls/` (manager)
All scheduled/executed call attempts. Stats strip (Total, Scheduled, Active,
Completed, Failed). Filters by status, phase (Pre/Post), and agent, plus a toggle
to show projected upcoming calls (light amber rows).

Columns: **Time** (scheduled_time/created_at), **Agent** (call.visit.agent),
**Context** (client name or visit title link), **Phase** (PRE/POST badge),
**Status** pill (Upcoming/Completed/In Progress/No Answer/Failed/Initiated/
Scheduled), **Details** (transcript snippet + optional audio player + summary).
Per row: `scheduled_time`, `visit.agent`, `visit.client.name`, `phase`, `status`,
`transcript`, `summary`, `summary_title`, `recording_url`.

### Live Agent — `/manager/agent-chat/` (manager)
Read-only chat to query sales data ("does not take actions"). Header shows LLM
connection status (green if `ANTHROPIC_API_KEY` set, else red) and a "New Chat"
button. Welcome message offers four quick actions (Today's visits, Agent
workload, Call performance, Client overview); messages POST to a
`LiveAgentChatAPI` endpoint and render markdown/tables client-side.

Context: `llm_configured` (boolean). No Django form — AJAX to
`/manager/agent-chat/api/` with `{message}`.

---

## Manager — clients

### Client List — `/manager/clients/` (manager)
All clients, searchable by name/domain/industry. Rows are enriched with
computed stats; header stats show total, with-AI-summary, CRM-linked, and
stale-sync counts. "New client" creates a manual entry; rows link to detail.

Columns: **name** + email domain, **industry**, **Visits** (total + last-visit),
**Agents** (unique count), **Intel** (AI-summary + CRM-linked badges), **Last
synced** (timestamp + fresh/stale badge). Enrichment: `total_visits`,
`last_visit_str`, `agent_count`, `intel_ai_on`, `intel_crm_on`, `synced_ago`.

### Client Detail — `/manager/clients/<id>/` (manager)
One client's full profile. Manager can edit "lessons learned" (auto-updated by
the LESSONS_DISTILL run after post-calls), read the AI summary, browse visit
history + recent calls, see assigned agents, and view CRM metadata.

Fields/sections: name, **status** badge, **industry**, **domain**, **crm_id**,
last-sync; **Visit History** (date, agent, methodology, status); **Recent Calls**
(agent, phase, time); **ai_summary** (read-only); **lessons_learned** (editable
textarea → `client_lessons_update`); **Contacts** (from `Client.contacts` JSON:
name, role, email, phone); **Assigned Agents** (name, email, methodology);
**CRM Data** (crm_id, deal_history count, interaction_history count).

### Client Form — `/manager/clients/add/` and `/manager/clients/<id>/edit/` (manager)
Create/edit a client; on edit a "Danger zone" exposes delete (→ `client_delete`).
`ClientForm` fields: **name** (text, required), **crm_id** (text, required, help
"External identifier for syncing from the CRM"), **domain** (text, optional),
**industry** (text, optional), **ai_summary** (textarea, optional, "used in
pre-call coaching prompts").

---

## Manager — people (agents)

### Agent List — `/manager/agents/` (manager)
All sales agents with config summary + performance. Each row annotated with
today's visit load, total completed calls, and configuration-issue flags
(missing phone/methodology/email). "New agent" creates an account.

Columns: **Agent** (avatar, name, email), **Methodology**
(`default_methodology.name` or —), **Today's load** (bar), **Done**
(complete/total today), **Success** (% of completed calls). Stats: total agents,
configured count, live-now count, avg success. Enrichment: `visits_today`,
`visits_complete_today`, `total_calls`, `call_success_rate`, `has_phone`,
`issues`, `is_configured`.

### Agent Detail — `/manager/agents/<id>/` (manager)
One agent's profile with inline editing. POST saves and logs an activity entry.
Loads 20 recent visits + 10 recent calls; a Configuration section shows on/off
dots for required fields.

Editable: **first_name** ("Prenume"), **last_name** ("Nume"), **email**,
**phone_number** ("Telefon", tel, "+40722000000"), **default_methodology**
(select of active methodologies, "— Niciuna —"). Read-only: Recent Visits (date,
client+industry, methodology, status), Recent Calls (phase, client, time-ago),
Configuration indicators, stat row (visits, calls, success rate).

### Agent Form — `/manager/agents/add/` (manager)
Create a sales agent (`AgentCreateForm`, with password + validation). Saves a
`User` with `is_sales_agent=True`, logs the action, redirects to the agent list.

Fields: **username** (required), **first_name**, **last_name**, **email**
(required), **phone_number** (tel, "used to place pre/post-call AI
conversations"), **pipedrive_user_id** (number, "maps this agent to a Pipedrive
user"), **password1** + **password2** (validated, must match).

---

## Manager — prompt engineering

These three concepts stack: a **Methodology** is the sales framework (e.g. SPIN,
MEDDIC, with an optional PDF + AI summary); **Voice Prompts** are the literal
system prompt + greeting spoken on PRE/POST calls (one active per type);
**Mega Prompts** are versioned meta-prompts that instruct Claude how to *assemble*
a visit-specific prompt; each assembly is recorded as a **Generation Run**.

### Methodology List — `/manager/methodologies/` (manager)
Grid of methodology cards (name, short description, agent/visit usage, PDF + AI
badges) with status toggles (All/Active/Archived) and summary stats (total,
active, with-PDF). Cards link to edit. Enrichment: `is_system_default`,
`status_tone/label`, `desc_short`, `agents_using`, `visits_using`, `has_pdf`,
`has_summary`.

### Methodology Form — `/manager/methodologies/add|<id>/edit/` (manager)
Create/edit a methodology. `MethodologyForm` fields: **name** (text, required),
**description** (textarea), **source_material** (PDF upload — validated by
`%PDF-` magic bytes, ≤10 MB, content-type/extension), **ai_summary** (textarea,
auto-generated from the PDF, editable), **is_active** (checkbox). When editing, a
Status card shows PDF-attached / AI-summary-ready / active indicators.

### Prompt List — `/manager/prompts/` (manager)
All `VoicePrompt`s grouped by **prompt_type** (PRE/POST), with the single active
prompt per type surfaced in a summary card (name + truncated system_prompt). Rows
show name, active badge, created_at, system_prompt preview, and greeting preview.
A collapsible note lists template variables `{agent_name}`, `{customer_name}`,
`{meeting_title}`.

### Prompt Form — `/manager/prompts/<id>/edit/` (manager)
Inline edit of one VoicePrompt with a live preview (dummy substitution: John Doe,
Acme Corporation, Q4 Product Demo). Fields: **name** (text), **prompt_type**
(PRE/POST select), **system_prompt** (textarea, required, monospace),
**first_message** (textarea, greeting), **is_active** (checkbox — "only one
active per type").

### Mega Prompt List — `/manager/mega-prompts/` (manager)
Versioned meta-prompts grouped by **domain** (Pre-call / Post-call / Lessons
distill). A stats row shows the active version per domain (Active/None). Each
domain section has a "New version" button and a table: **Version** (v1, v2…),
**Name**, **Status** (Active/Inactive), **Updated**, **Actions** (Edit/Activate).
Reference card explains: editing always creates a new version; old versions are
kept; activating one deactivates siblings in the domain.

### Mega Prompt Form — `/manager/mega-prompts/new|<id>/edit/` (manager)
Create/edit a mega-prompt version (always saved **inactive**). Fields: **name**
(text, required), **domain** (PRE_CALL/POST_CALL/LESSONS_DISTILL — locked on
edit), **meta_prompt** (large monospace textarea — the instructions sent to
Claude; supports `{placeholders}` like `{client_name}`, `{methodology_summary}`,
`{manager_notes}`; backtick-wrapped tokens pass through to dial-time). Submit
label: "Save as new version (inactive)".

### Generation Run List — `/manager/generation-runs/` (manager)
Paginated audit log (50/page) of every Auto-Prompt-Assembler run. Filters by
**domain** and **outcome** (Any/Success/Failures). Columns: **When**, **Domain**,
**Target** (Visit #/Client #/—), **Trigger** (MANUAL/SCHEDULED/END_OF_MEETING),
**Status** (ok/fail), **Tokens** (input/output), details link.

### Generation Run Detail — `/manager/generation-runs/<id>/` (manager)
One run's full audit trail with **decrypted PII** (superuser-only; the read is
itself logged). Header: domain, created_at, triggered_by, tokens, success/fail
(+ error if failed). Four monospace sections: **Context bundle** (JSON), **Claude
request** (rendered prompt), **Claude response** (raw output), **Parsed outputs**
(JSON). Model fields: `domain`, `triggered_by`, `success`, `error`,
`input_tokens`, `output_tokens`, `context_bundle`, `claude_request`,
`claude_response`, `parsed_outputs` (the last four encrypted at rest). Links to
the related visit/client/mega-prompt.

---

## Manager — configuration & audit

### Settings — `/manager/settings/` (manager)
Edits the singleton `GlobalSettings` (`GlobalSettingsForm`). Fields:
**pre_call_offset_minutes** (default -60, "before meeting"),
**post_call_offset_minutes** (default 15, "after meeting"),
**retry_interval_minutes** (default 5, "between retries"), **default_methodology**
(select of active methodologies — "system-wide fallback when no agent or visit
override is set"). A sidebar explains how each setting applies; an info box points
to Mega Prompts for meta-prompt management.

### Logs — `/manager/logs/` (manager)
Read-only audit explorer (`get_activity_logs_filtered`). Filter by **level**
(DEBUG/INFO/WARNING/ERROR/CRITICAL) and **user** (sales agents). Columns:
**Time**, **Level** (colored badge), **Action**, **User** (avatar+name or
"System"), **Details** (collapsible JSON / linked visit title). Immutable — no
write actions.
