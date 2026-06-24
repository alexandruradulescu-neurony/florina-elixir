# Prep notes — voice/chat slice + multitenancy mapping

**Date:** 2026-06-24
**Status:** Research & options only — **no decisions made**. This exists to make our
next brainstorm faster and better-informed. Nothing here is a commitment.
**Feeds:** the two design specs in [`../specs/`](../specs/):
the [Elixir/Phoenix/Oban port](../specs/2026-06-24-elixir-phoenix-port-design.md) and the
[database-per-tenant multitenancy](../specs/2026-06-24-multitenancy-database-per-tenant-design.md) design.

---

## 1. What the first slice actually is today (read from the current Django code)

The spec names the first slice as **"voice calls + the live agent chat."** Mapping that
to the real endpoints in the live app:

**Belongs to the slice (candidate to move to Phoenix):**

| Endpoint (Django) | What it does |
|---|---|
| `POST /webhooks/elevenlabs/` | Receives call/conversation events from the ElevenLabs voice agent |
| `POST /webhooks/twilio/` | Receives telephony events from Twilio (the phone layer) |
| `GET /manager/agent-chat/` | The live agent chat screen (operator-facing) |
| `POST /manager/agent-chat/api/` | The chat's message endpoint (sends a message, gets an AI reply) |
| `.../visits/<id>/call/<phase>/`, `dashboard/admin/test-call/` | Kick off an outbound call |
| `GET /healthz/` | Health check (trivial; could move or stay) |

**Stays in Django for now (per the spec — no concurrency benefit):** every CRUD screen
(visits, clients, agents, methodologies, prompts, mega-prompts, generation runs, settings),
Google Calendar OAuth/sync, the dashboards, post-call analysis, prompt assembly, and PDF.

### How it works today (the important part)

- **Telephony + voice:** Twilio handles the phone line; ElevenLabs runs the conversational
  voice agent. The Django app orchestrates them over plain **REST calls** (`requests.get/post`)
  and **receives signed webhooks** for events. It does **not** hold any persistent live
  connections — the live audio flows between Twilio and ElevenLabs, not through the app.
- **Live agent chat:** despite the name, it is currently a simple **request → response** JSON
  call: the operator types a message, the server calls Claude once, and returns the full reply.
  No streaming, no websockets.
- **Webhook security (must be reproduced exactly):**
  - ElevenLabs → HMAC-SHA256 over `"{timestamp}.{raw_body}"`, header
    `ElevenLabs-Signature: t=<unix_ts>,v0=<hex>`, with a 30-minute replay window.
  - Twilio → HMAC-SHA1 over URL + sorted params (Twilio's validator).
  - Both **fail closed**: if the secret isn't configured, the request is rejected.
  - The keys already exist locally in `.env` (`ELEVENLABS_*`), carried over from Django.
- **Background jobs that exist today** (`voice/tasks.py`) — mostly scheduled: calendar sync,
  CRM sync, `sync_pending_calls`, `process_visit_pre_calls`, `process_visit_post_calls`,
  and `process_visit_post_call_completion` (event-triggered after a call). A separate
  scheduler process drives the periodic ones.

> **The takeaway:** today's design is REST + webhooks + one-shot chat. Elixir's strength
> (holding many live connections) is therefore an **upgrade opportunity**, not a like-for-like
> port. That reframes the slice from "copy what exists" to "rebuild the realtime parts the way
> they should work."

---

## 2. Candidate slice boundary — needs your confirmation

Clear-cut **move**: the two webhook receivers, the live agent chat (screen + message endpoint),
and call initiation.

Clear-cut **stay**: all CRUD, prompt/methodology systems, calendar, dashboards, post-call
analysis/PDF.

**Grey zone (decide together):** the scheduled-dialing jobs (`sync_pending_calls`,
`process_visit_pre_calls`, `process_visit_post_calls`) and `process_visit_post_call_completion`.
They touch both the voice flow *and* visit data that lives in Django. Two clean options:
keep them in Django's scheduler for now (smallest slice), or move them to Phoenix/Oban (more
of the voice flow in one place, but needs access to visit data — see §4).

---

## 3. Building the slice in Phoenix — options & tradeoffs (no decision yet)

### 3a. The live agent chat
- **Option A — streaming live page (recommended).** Rebuild it as a Phoenix LiveView that
  streams Claude's reply token-by-token. Server-rendered, almost no custom JavaScript, and a
  real UX upgrade over today's wait-for-the-whole-answer behaviour. This is exactly what
  LiveView is for, and a low-risk first win to learn the framework on.
- **Option B — port the JSON endpoint as-is.** Least effort, least benefit; keeps the current
  one-shot behaviour. Reasonable only if we want the smallest possible first step.

### 3b. Telephony + voice (Twilio / ElevenLabs)
- **Webhook receiver:** a Phoenix endpoint plus a small "verify the signature" plug that
  reproduces the HMAC checks above (fail-closed, replay window). Phoenix gives us the **raw
  request body** cleanly, which the signature check needs.
- **Call orchestration:** the outbound REST calls port directly. `Req` (already a dependency)
  is the Elixir equivalent of Python's `requests`.
- **The realtime upgrade (where Elixir earns its place):** use Phoenix **Channels** to hold
  live connections and push call status / transcripts to operator dashboards as they happen,
  and (later, if wanted) to bridge Twilio Media Streams ↔ ElevenLabs through Phoenix. This is
  the part that is genuinely awkward on the current stack.

### 3c. Background jobs → Oban
- Event-triggered work (e.g. post-call completion fired from a webhook) becomes an **Oban
  worker** — enqueue from the webhook handler, process out of band.
- Periodic work (the scheduled dialers) maps to **Oban's Cron plugin** *if/when* we move it;
  otherwise it stays on Django's scheduler. The skeleton's example worker shows the shape.

---

## 4. Honouring database-per-tenant (the Track 1 contract) — options

Track 1 requires **one physically separate database per customer** plus a small control-plane
database (the registry of who lives where). Phoenix/Ecto supports this cleanly:

- **Mechanism — Ecto "dynamic repositories":** keep one control-plane repo for the registry,
  and open a connection per tenant database on demand. A request resolves its tenant, then
  pins this process to that tenant's connection (`Repo.put_dynamic_repo/1`); every query for
  the rest of the request goes to that tenant's database. Resolve-fails → **reject** (no data).
- **Tenant resolution:** the multitenancy spec's recommended default is **subdomain per
  tenant** (e.g. `acme.…`), which works before login. A plug resolves it early, the same way
  Django's middleware does.
- **The realtime-specific catch (important):** a websocket/LiveView connection is long-lived
  and spans many operations, so the tenant must be resolved **once at connect/mount time**,
  stored on the connection, and re-applied to each database touch. The port spec already flags
  that "every real-time connection will eventually need to know which tenant it belongs to" —
  this is the concrete reason to design the slice against the tenancy contract from the start.
- **Shared-data access (spec open decision #3):** Phoenix can either talk to the per-tenant
  databases **directly** (simplest for realtime) or go **through a Django internal API**
  (cleaner long-term boundary). Direct access is the likely starting point; worth a deliberate
  decision.

---

## 5. Questions to settle in the next brainstorm

1. **Slice boundary:** confirm the grey-zone scheduled jobs — stay in Django, or move to Oban?
2. **Live chat:** upgrade to a streaming live page (Option A), or port as-is first (Option B)?
3. **Routing:** how do requests split between Django and Phoenix — reverse-proxy paths, or a
   subdomain? (spec open decision #2)
4. **Shared data:** direct per-tenant DB access from Phoenix, or via a Django API? (open #3)
5. **Tenancy:** confirm subdomain resolution, and how realtime connections carry their tenant.

None of the above is decided here. When you're back, we brainstorm these, write the slice's
own spec, then plan and build it.
