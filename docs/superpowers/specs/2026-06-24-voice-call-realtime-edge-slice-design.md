# Slice 1 — Voice Call Real-Time Edge (Elixir/Phoenix)

**Date:** 2026-06-24
**Status:** Draft for review
**Repo:** `florina-elixir` (the Elixir port)
**Relationship:** First concrete slice of the
[Elixir/Phoenix/Oban port](2026-06-24-elixir-phoenix-port-design.md). Consumes the
[database-per-tenant contract](2026-06-24-multitenancy-database-per-tenant-design.md).
Grounded in [the prep notes](../notes/2026-06-24-voice-slice-and-multitenancy-prep.md)
and the current Django code (in git history).

---

## Summary (plain English)

Move **only the real-time edge** of the AI voice calls into Phoenix: receiving the
Twilio/ElevenLabs webhook events and showing calls live on a dashboard. **Django stays
the brain** — it still schedules calls, assembles the prompts, stores all the data, and
runs the post-call analysis. Phoenix reads and writes the shared per-tenant database for
the few things it needs.

## Why this is the right first slice

The whole app is one connected pipeline:

> Calendar → **Visit** (links agent + client + methodology + scenario) → auto prompt
> assembly → **AI voice call** → transcript → post-call analysis → lessons + CRM.

The voice call is the *last link*. Lifting the whole pipeline into Phoenix would drag
most of the app's data and logic with it. The **edge** (telephony events + live
visibility) is the only cleanly separable, genuinely real-time part — and it's exactly
where Elixir's strength (many live connections) pays off. Keeping the linked data in one
place (Django) avoids splitting tightly-coupled data across two systems.

It also de-risks the Elixir bet: bounded scope, with the hard data/prompt logic left in
proven Django.

## Scope

**In (moves to Phoenix):**
- Webhook receivers for **Twilio** and **ElevenLabs**, signature-verified and fail-closed.
- A **live "calls" dashboard** (Phoenix LiveView + PubSub) showing each call's lifecycle
  in real time (ringing → answered → in progress → completed / failed / retrying).
- **Tenant-aware shared-DB access**: read the call context Django prepared; write call
  status and transcript back so Django's analysis picks them up.

**Out (stays in Django, unchanged):**
- Call scheduling and initiation, prompt assembly, post-call analysis, CRM sync, and all
  CRUD/management screens.

**Stretch (flagged — needs verification, not committed for slice 1):**
- Live **during-call** transcript streaming. This depends on ElevenLabs real-time events
  / Twilio media streams. Slice 1 streams live **status**, and shows the transcript as
  soon as the post-call webhook arrives. True live transcription is a follow-up once the
  integration's real-time capability is confirmed.

## Architecture

- Phoenix runs alongside Django, sharing the same per-tenant PostgreSQL databases.
- **Routing:** a reverse proxy sends `/webhooks/twilio`, `/webhooks/elevenlabs`, and the
  live-calls dashboard path to Phoenix; everything else continues to Django.
- **Tenancy:** tenant resolved by subdomain (Track 1 default) and used to pin Ecto's
  dynamic repository to that tenant's database — for HTTP requests **and** for each live
  connection at connect time. Fail-closed if the tenant can't be resolved.
- **Data access:** Ecto schemas mapping only the tables this slice touches (primarily
  `CallAttempt`, plus minimal `Visit`/`Client` fields for display). Read-mostly; the one
  write path is call status + transcript.

## Components

1. **Webhook endpoints + signature-verification plug** — reproduce the Django logic
   exactly (ElevenLabs: HMAC-SHA256 over `"{timestamp}.{body}"`, 30-minute replay window;
   Twilio: HMAC-SHA1 validator). Fail-closed. Source of truth: `voice/webhook_security.py`
   in git history.
2. **Live calls dashboard** — a LiveView subscribed via Phoenix PubSub; the webhook
   handler broadcasts call events; the dashboard updates live for every connected manager.
3. **Tenant plug + dynamic-repo resolution** — resolves and pins the tenant DB.
4. **Ecto schemas** — map the existing tables (no schema changes to the database).
5. **Oban** — for any out-of-band work a webhook triggers (e.g., flagging a completed
   call for Django's analysis), using the skeleton's worker pattern.

## Data flow

```
Django schedules + initiates the call
        │
Twilio / ElevenLabs emit lifecycle + post-call events
        │
Phoenix webhook endpoint  ── verify signature (fail-closed)
        │
update CallAttempt (tenant DB)  ──broadcast──▶ live dashboard updates
        │
on post-call event: write transcript/status
        │
Django's existing post-call analysis picks it up (unchanged)
```

## The seam (precise integration contract)

- **Phoenix writes:** call status transitions, transcript, and timestamps on `CallAttempt`.
- **Phoenix reads:** the call context Django prepared, plus minimal visit/client fields
  for the dashboard.
- **Django owns (unchanged):** scheduling, initiation, prompt assembly, analysis, CRM.
- **Contract:** the `CallAttempt` fields and status values are the agreed interface
  between the two apps. Pin these exactly during planning (read the current model from
  history first).

## Security

Reproduce signature verification exactly; fail-closed; enforce the replay window; secrets
from environment (`ELEVENLABS_*`, `TWILIO_*`). Role-based access on the dashboard.

## Cutover (reversible)

Point the Twilio/ElevenLabs webhook URLs (or proxy `/webhooks/*`) at Phoenix. Fully
reversible — point them back at Django to roll back.

## Testing (local only, per project rule)

- Signature verification: valid / invalid / expired / replayed → fail-closed.
- Webhook → correct `CallAttempt` update → broadcast received.
- **Tenant isolation (highest priority):** a request/connection resolved as tenant A can
  never read or write tenant B's database. Mirrors the Track 1 leakage test.
- Live dashboard reflects an incoming event.

## Open decisions (confirm during planning)

1. **Live during-call transcript** — verify ElevenLabs real-time capability. If not ready,
   slice 1 = live status + transcript-on-completion (recommended default).
2. **Exact `CallAttempt` contract** — fields and status values (read the current Django
   model from history).
3. **Routing mechanism** — reverse-proxy paths vs. subdomain split (ties to tenancy).
4. **Write path** — Phoenix writes directly to the tenant DB (simplest; default), vs. a
   thin internal Django endpoint for writes (cleaner boundary). Revisit if direct writes
   cause coupling pain.

## Out of scope

- Everything non-real-time (prompt assembly, scheduling, analysis, CRUD, CRM) — stays in
  Django.
- A committed timeline for further migration — re-decided after this slice proves out.
