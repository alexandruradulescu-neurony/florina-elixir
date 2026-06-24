# Slice 2 — Live Agent Chat (streaming LiveView + Claude)

**Date:** 2026-06-24
**Status:** Draft for review
**Repo:** `florina-elixir`
**Relationship:** Independent of the voice slices. Reuses the dashboard Basic Auth from
[Slice 1b](2026-06-24-live-calls-dashboard-slice-design.md).

---

## Summary (plain English)

A chat page where a manager asks the AI assistant a question and the answer **streams in
live, word by word**. Today (in Django) this is a one-shot call — you wait for the whole
answer. Phoenix LiveView turns it into a live stream, which is both a real UX upgrade and a
clean showcase of what Elixir is good at.

## Why now

It's self-contained, high-visibility, and uses the `ANTHROPIC_API_KEY` you already have.
No dependency on the voice/data plumbing.

## Scope

**In:**
- A LiveView chat page at `/chat`, behind the same password gate as `/calls`.
- Streaming responses from Claude (`claude-sonnet-4-6`) — tokens appear as they arrive.
- Conversation history kept in the LiveView for the session (multi-turn).

**Out (later slices):**
- Feeding the app's own data (clients, visits, methodologies) into the chat as context — v1
  is a general assistant; data-grounding is a focused follow-up.
- Saving chat history to the database; extended "thinking"; multiple conversations.

## Architecture

- **No official Anthropic SDK for Elixir** → call the Messages API over **raw HTTP with
  `Req`** (already a dependency), using **SSE streaming** (`"stream": true`). This is the
  documented approach for languages without an SDK.
- `Florina.Anthropic.stream_chat/2` — POSTs the conversation to `/v1/messages` with
  `stream: true` and the required headers (`x-api-key`, `anthropic-version: 2023-06-01`),
  parses the SSE events, and invokes a callback for each `text_delta`.
- `FlorinaWeb.ChatLive` — holds the message list. On submit, it spawns a `Task` that calls
  `stream_chat`; each delta is sent to the LiveView process, which appends it to the
  in-progress assistant message and re-renders. The browser shows tokens live.
- **The API key stays server-side** — the LiveView (server) calls Anthropic; the browser
  never sees the key.
- Route `/chat` sits behind the existing `:dashboard_auth` pipeline.

## Components

1. `Florina.Anthropic` — the streaming client (build request, stream SSE, per-delta callback,
   surface errors). Model + key from config/env.
2. `FlorinaWeb.ChatLive` — the chat UI (message list, input, live-updating assistant turn).
3. Route for `/chat` behind `:dashboard_auth`.
4. Config: `ANTHROPIC_API_KEY` (env) + the model id (default `claude-sonnet-4-6`).

## Decision needed

**v1 plain assistant vs. data-grounded now.** Recommended: ship **v1 as a general streaming
assistant** (smallest valuable slice, proves the streaming + Anthropic integration), then add
app-data grounding (the manager can ask about *their* clients/visits) as a focused follow-up.
Grounding now would pull in data-assembly and token-budget work that's better isolated.

## Security

- `ANTHROPIC_API_KEY` from env, server-side only — never sent to the browser.
- Reuse the `/calls` password gate (`:dashboard_auth`).

## Testing (local only)

- `Florina.Anthropic`: stub the HTTP layer (no real API calls, no token spend) and assert SSE
  parsing turns a sample event stream into the right sequence of text deltas; assert error
  handling (non-200, malformed event).
- `ChatLive`: with a stubbed client, a submitted message renders a streamed assistant reply;
  auth gate rejects unauthenticated access.

## Open decisions

1. **Data grounding** — v1 plain (recommended) vs. now.
2. **Model** — `claude-sonnet-4-6` (default); configurable.
3. **Thinking** — off for v1 (snappy); adaptive thinking is an easy later toggle.

## Out of scope

- Voice slices, multitenancy, chat persistence — separate.
