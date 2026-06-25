# Manager / Agent Roles — Design

**Date:** 2026-06-26
**Status:** Approved decisions captured; implementation pending green light.
**Context:** Phase 1 agent SSO + multi-provider calendar is live. This adds a
**role split** (manager vs agent) and, critically, a **per-agent data boundary**
("agents see only their own calls + meetings"). Builds on
`2026-06-25-agent-sso-multi-provider-calendar-email-design.md`.

## Goal

Two roles inside each tenant:

- **Manager** — sees everything in the tenant: unified calendar (all agents'
  meetings), all calls, a live activity dashboard, AI chat. Can edit meetings,
  clients, agents, and methodologies.
- **Agent** — sees **only their own** meetings and calls. Sees the (shared)
  client list. Can trigger Florina's **post-call debrief** for one of their
  meetings if they missed the daily call.

## The security boundary (the important part)

"Agents see only their own" is enforced **in the database queries**, not in the
UI. An agent must not be able to reach a teammate's meetings/calls by editing a
URL. Policy lives in **one** place and every list query references it.

```
Florina.Authz.scope(user) ::
  :all              # manager — no filter
  {:own, user.id}   # agent  — filter to this user
```

Every agent-facing list function takes a `scope` and applies it:

- **Meetings (visits):** `voice_visit.agent_id` already exists (NOT NULL).
  `{:own, id}` → `where(agent_id == id)`.
- **Calls:** no direct owner; owned via `visit.agent_id`. `{:own, id}` →
  `join(:visit) |> where(visit.agent_id == id)`.
- **Calendar events:** `calendar_events.user_id` already exists.
  `{:own, id}` → `where(user_id == id)`.
- **Clients:** tenant-global, **no per-agent filter** (agents see all clients,
  by design — only calls/meetings are private).

## Data model change

One additive tenant migration:

- `voice_user.role` — `Ecto.Enum, values: [:manager, :agent], default: :agent,
  null: false`.
- Keep `is_sales_agent` as-is (means "has meetings / is dialable"); orthogonal
  to `role`. A manager may also be a sales agent.
- New SSO sign-ins default to `role: :agent`. The first manager is promoted by
  the operator (see Role assignment).
- Applied to all tenant schemas on deploy via the existing `BootMigrator`; new
  tenants get it through the provisioner's migrate step.

Manager-oriented columns already on `voice_visit` are reused (no new columns):
`manager_notes`, `pre_call_prompt_locked`, `post_call_prompt_locked`, etc.

## Role assignment (decision: seed first, managers do the rest)

- **Operator** promotes the first manager from `/admin`: a per-tenant **Agents**
  panel lists the tenant's users (pins that tenant's schema prefix) with
  role + active toggles.
- **Managers** then manage agents in-app (promote/demote, activate/deactivate)
  via the manager **Agents** screen.

## Routing & authorization

- New plug `require_manager` (runs after `agent_auth`): 403/redirect unless
  `current_agent.role == :manager`.
- **Shared, role-scoped** (both roles; data filtered by `Authz.scope/1`):
  `/t/:slug/calendar`, `/t/:slug/calls`, `/t/:slug/clients` (read).
- **Manager-only** (`require_manager`): `/t/:slug/chat` (AI chat),
  `/t/:slug/manage/dashboard`, `/t/:slug/manage/meetings` (+ edit),
  `/t/:slug/manage/clients` (edit), `/t/:slug/manage/agents`,
  `/t/:slug/manage/methodologies`.
- **Agent-only:** `/t/:slug/today` (my meetings today + "have Florina call me").
- Nav in `Layouts.agent_app` adapts to role.

## Live view (decision: activity dashboard, no listen-in)

Manager dashboard updates in real time via Phoenix PubSub: today's meetings
across all agents, each meeting's call status, and recent call results. No live
audio/transcript streaming (deferred). Call-status changes broadcast from the
existing webhook / `PostCallCompletion` path.

## Agent "have Florina call me" (decision: post-call debrief only)

On the agent **Today** screen, a button per meeting enqueues the **post-call
debrief** for that visit (the existing post-call `DialCall`/`PostCallCompletion`
path). Guarded by the existing dial-dedup unique job. Pre-call briefings are not
triggered this way.

## Phasing

**Phase 1 — Foundation (security backbone).** `role` column + migration;
`Florina.Authz` scope policy; `manager?/1`; scope the existing
calendar/calls/chat queries (agents → own, managers → all, chat → manager-only);
`require_manager` plug; operator `/admin` per-tenant Agents panel to seed the
first manager; role-aware nav. *Deliverable: the data boundary is live and you
can make yourself a manager.*

**Phase 2 — Manager screens.** Live activity dashboard; meetings list + edit
(incl. `manager_notes` + lock flags); client edit; in-app agent management;
methodology editor.

**Phase 3 — Agent screens.** "My meetings today"; client list (read); "have
Florina call me" → post-call debrief.

## Testing

- Authz: manager scope returns `:all`; agent scope returns `{:own, id}`.
- Isolation: agent A cannot load agent B's meetings/calls via the scoped
  context functions (query-level test, the core security check).
- `require_manager` blocks an agent from manager routes; allows a manager.
- Role defaults to `:agent` on SSO upsert; operator promotion flips it.

## Out of scope (for now)

Live call audio/transcript monitoring; per-client agent ownership; manager
hierarchy/teams; email (Phase 2 mailbox tracked separately).
