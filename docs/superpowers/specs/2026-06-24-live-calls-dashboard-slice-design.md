# Slice 1b — Live Calls Dashboard (Phoenix LiveView)

**Date:** 2026-06-24
**Status:** Draft for review
**Repo:** `florina-elixir`
**Relationship:** Builds directly on [Slice 1a](2026-06-24-voice-call-realtime-edge-slice-design.md)
(the ElevenLabs webhook ingestion). Consumes the `"calls"` PubSub broadcast that 1a already emits.

---

## Summary (plain English)

A web page that shows calls **updating live** — no refresh. When a call's status or
transcript changes (driven by the webhooks from slice 1a), the row updates itself on the
screen in real time. This is the first piece that turns the plumbing into something you
can watch, and the first real use of Phoenix's live-page capability.

## Why now

Slice 1a already broadcasts `{:call_updated, call}` on the `"calls"` topic every time a
webhook lands. This slice is the consumer: a LiveView page that subscribes and re-renders.
Small, self-contained, high visibility — the ideal next step.

## Scope

**In:**
- A LiveView page listing recent calls, newest first.
- Live updates: when a `{:call_updated, call}` broadcast arrives, the matching row updates
  (or a new call appears) without a page refresh.
- A `Calls.list_recent/1` query for the initial page load.

**Out (later slices):**
- Filtering/search, pagination, per-call detail pages.
- Per-tenant database routing (this slice uses the default repo, like 1a).
- Twilio call events (separate slice) — the dashboard will pick them up automatically once
  they broadcast on the same topic.

## Architecture

- `FlorinaWeb.CallsLive` (LiveView): on `mount`, if connected, subscribe to
  `Phoenix.PubSub` topic `"calls"`; load recent calls via `Calls.list_recent/1` into a
  LiveView stream. `handle_info({:call_updated, call}, socket)` upserts the row in the stream.
- Reuses the existing `Florina.Calls` context and `CallAttempt` schema from slice 1a.
- Renders a simple table: phase (PRE/POST), status, external call id, a transcript/summary
  snippet, and last-updated time.

## Access control — decision needed

The page displays call transcripts/summaries, which are sensitive. The Phoenix app has no
authentication yet. Options for this slice:

- **Recommended: HTTP Basic Auth** via `Plug.BasicAuth` on the dashboard route, with the
  username/password read from env vars. Cheap, gates the page on the deployed instance,
  no full auth system needed yet.
- **No auth yet:** acceptable only if the deployed instance stays private/unshared; faster
  but leaves call data reachable by URL.
- **Full auth** (`phx.gen.auth`): out of scope for this slice — a larger, separate effort.

## Components

1. `Florina.Calls.list_recent/1` — recent calls, newest first, with a sane default limit.
2. `FlorinaWeb.CallsLive` — the LiveView (mount/subscribe/stream + handle_info).
3. Route for the dashboard (e.g. `/calls`), behind the chosen access control.
4. (If Basic Auth chosen) a small pipeline/plug reading credentials from config/env.

## Testing (local only)

- `Phoenix.LiveViewTest`: the page mounts and renders existing recent calls.
- Broadcasting `{:call_updated, call}` updates the rendered page live (row appears/updates).
- (If Basic Auth) a request without/with wrong credentials is rejected; correct passes.

## Open decisions (confirm before planning)

1. **Access control** — Basic Auth (recommended) vs none-yet vs full auth.
2. **Route path** — `/calls` (default) or something else.
3. **How many recent calls** to show on load (default: 50).

## Out of scope

- Tenancy, Twilio events, detail pages, search — all later.
