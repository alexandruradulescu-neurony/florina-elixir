# Agent SSO + Multi-Provider Calendar & Email (Google + Microsoft)

**Date:** 2026-06-25
**Status:** Design agreed; build on green light
**Repo:** `florina-elixir`
**Relationship:** Builds on the [multi-tenant foundation](2026-06-24-multitenancy-foundation-elixir-slice-design.md),
the [backend port](../plans/2026-06-25-backend-port.md), and the
[central config distribution](2026-06-25-central-config-distribution-design.md).
Replaces today's operator-triggered Google calendar connect
(`GoogleOAuthController`, behind shared `dashboard_auth`) with agent self-service sign-in.

---

## Summary (plain English)

Today an **operator** connects a calendar *for* an agent, behind one shared dashboard password,
and only Google is supported. This redesign flips that and widens it:

1. **Agents sign themselves in** with their own work **Google _or_ Microsoft** account. One
   sign-in does two jobs: it **creates/finds their account** and **grants Florina read access
   to their calendar**.
2. **Only company emails are accepted.** We trust the *verified* email Google/Microsoft returns;
   if its domain is on that company's allow-list, the agent is auto-approved. Otherwise they are
   turned away and no account is created.
3. **One merged calendar.** A background job keeps a synced copy of *every* agent's appointments
   (Google or Microsoft) in the company database; the in-app calendar shows them all together.
4. **Florina gets her own mailbox** (Phase 2): each company connects one dedicated mailbox
   (e.g. `florina@theircompany.com`) via Google or Microsoft, and Florina sends as that address.
   Florina has **no** calendar of her own.

Agent-facing pages move behind each agent's **personal login** (the shared dashboard password is
retired for them). The operator `/admin` console (bcrypt) is unchanged.

---

## Provider model (the "Google-or-Microsoft" switch)

A single set of behaviours, two implementations, dispatched by a `provider` atom. This is the
core of "build it once, works for both."

- **`Florina.Integrations.OAuthProvider`** (identity + tokens)
  - `authorize_url(redirect_uri, state)` → consent-screen URL
  - `exchange_code(code, redirect_uri, client)` → `%{access_token, refresh_token, expires_in, scope}`
  - `refresh_token(cred)` → `%{access_token, expires_at}`
  - `fetch_identity(tokens)` → `%{email, email_verified, name, subject}`
- **`Florina.Integrations.CalendarProvider`** (read calendar)
  - `list_events(cred, time_min, time_max)` → normalized events (same map shape the existing
    `GoogleCalendar.list_events/3` returns: `id, title, start_time, end_time, attendees,
    description, raw`)
- **`Florina.Integrations.MailProvider`** (Phase 2 — send mail)
  - `send_mail(cred, %{to, subject, html, text})` → `:ok | {:error, reason}`

Implementations:
- **Google** — adapt the existing `GoogleOAuth` + `GoogleCalendar` modules to the behaviours.
  - Auth: `https://accounts.google.com/o/oauth2/v2/auth` with `access_type=offline&prompt=consent`
    (so we get a refresh token), scopes `openid email profile
    https://www.googleapis.com/auth/calendar.readonly` (+ `https://www.googleapis.com/auth/gmail.send`
    Phase 2).
  - Identity: verify `id_token` / call userinfo; require `email_verified == true`.
- **Microsoft** — new module(s) using Microsoft Graph via `Req`.
  - Auth: `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize`, token at
    `.../oauth2/v2.0/token`; `{tenant}` = `common` (multi-tenant) by default. Scopes
    `openid profile email offline_access Calendars.Read` (+ `Mail.Send` Phase 2).
  - Identity: claims from `id_token` (`preferred_username`/`email`, `name`, `oid`); require a
    verified work email.
  - Calendar: `GET https://graph.microsoft.com/v1.0/me/calendarView?startDateTime=…&endDateTime=…`
    with header `Prefer: outlook.timezone="UTC"`; normalize to the shared event shape.

A small dispatcher (`Florina.Integrations.Provider`) maps `:google | :microsoft` → impl module,
chosen per credential. Both impls are swappable in tests via app config (mirrors the existing
`:google_calendar_client` stub pattern).

---

## Data model

All per-tenant tables live in the **tenant** database (via `TenantRepo`); the allow-list lives
in the **control-plane** (`Florina.Repo`).

### New: unified `oauth_credentials` (per tenant) — replaces `voice_googleoauthcredential`

| Field | Type | Encrypted | Notes |
|---|---|---|---|
| `id` | id | | |
| `user_id` | FK → `voice_user` | | **nullable** — null for Florina's mailbox (Phase 2) |
| `provider` | enum `:google \| :microsoft` | | |
| `purpose` | enum `:agent_calendar \| :florina_mailbox` | | |
| `email` | string | | the connected account's verified email |
| `access_token` | binary | ✅ Cloak | |
| `refresh_token` | binary | ✅ Cloak | |
| `client_id` | string | | for per-customer apps; null when using the central app |
| `client_secret` | binary | ✅ Cloak | for per-customer apps |
| `token_uri` | string | | provider default |
| `scopes` | {:array, string} | | |
| `expires_at` | utc_datetime | | |
| timestamps | | | `created_at` / `updated_at` |

Unique index on `(provider, purpose, user_id, email)`. A migration creates this table and drops
the Google-specific `voice_googleoauthcredential` (no production data to preserve — leadder has
no calendar connected). The token-refresh + `ensure_valid_token` logic from `GoogleCalendar`
moves to shared credential helpers.

### New: `calendar_events` (per tenant) — backs the merged calendar

| Field | Type | Notes |
|---|---|---|
| `id` | id | |
| `user_id` | FK → `voice_user` | which agent's calendar |
| `provider` | enum | google/microsoft |
| `external_event_id` | string | provider's event id |
| `title`, `description`, `location` | string | |
| `start_time`, `end_time` | utc_datetime | |
| `attendees` | {:array, :map} | `[%{"email" => …}]` |
| `status` | string | provider status (confirmed/tentative/cancelled) |
| `raw` | :map | full provider payload |
| `synced_at` | utc_datetime | |
| timestamps | | |

Unique index on `(user_id, provider, external_event_id)` (idempotent upserts). This is the
**store of all events** for every agent; the in-app calendar reads it. The existing
visit-derivation (client-matched events → `Visit`) becomes a consumer of these rows.

### Changed: control-plane `Tenant` — `allowed_email_domains`

Add `allowed_email_domains` ({:array, string}, default `[]`) to the control-plane tenant
registry, editable in `/admin/tenants`. The sign-in callback reads it via `Tenants.get_by_slug/1`.

### Changed: agent `voice_user` — `active`

Add `active` (boolean, default `true`) so an operator can deactivate an auto-approved agent
without deleting the record. Login is refused for inactive agents.

### Watches / push notifications

Out of scope for this slice. The 30-min cron drives both providers' syncs. The existing Google
push-watch tables/code are left in place but unused by the new flow; Google watch renewal +
Microsoft Graph subscriptions are a later optimization.

---

## Authentication & sessions

New module **`FlorinaWeb.AgentAuth`** (mirrors the shape of the existing `AdminAuth`):
`log_in_agent/2`, `log_out_agent/1`, `fetch_current_agent/2` (plug),
`require_authenticated_agent/2` (plug), and `on_mount :ensure_authenticated` (LiveView).

- The session stores `agent_id` (+ the tenant slug already set by `:tenant_session`). After
  `ResolveTenant` pins the tenant DB, `fetch_current_agent` loads the agent from `TenantRepo`.
- On successful sign-in we **renew the session** (fixation protection) and store `agent_id`.

### Routes (per tenant)

```
scope "/t/:tenant_slug", FlorinaWeb do
  pipe_through [:browser, :resolve_tenant, :tenant_session]
  get  "/login",                  AuthController, :login        # provider buttons
  get  "/auth/:provider/start",   AuthController, :start        # → consent screen
  get  "/auth/:provider/callback",AuthController, :callback     # ← provider redirect
  delete "/logout",               AuthController, :logout
end

scope "/t/:tenant_slug", FlorinaWeb do
  pipe_through [:browser, :resolve_tenant, :tenant_session, :require_agent]
  # agent-facing pages move here, OFF :dashboard_auth:
  live "/calls", ...
  live "/chat", ...
  live "/calendar", ...   # the merged calendar (new)
end
```

`:dashboard_auth` (shared Basic-Auth) is removed from agent-facing pages. The old
`GoogleOAuthController` connect/callback routes are replaced by the unified `AuthController`.

---

## Sign-in flow (end to end)

1. Agent opens `…/t/<slug>/login`, clicks **Google** or **Microsoft**.
2. `start` signs a state token (`Phoenix.Token`: tenant slug + provider + nonce, 600s) and
   redirects to the provider's consent screen for identity **and** `Calendars.Read`.
3. Provider redirects back to `/auth/:provider/callback?code=…&state=…`.
4. `callback`:
   a. Verify state (reject if expired/tampered/provider-mismatch).
   b. `exchange_code` → tokens; `fetch_identity` → `%{email, email_verified, name, subject}`.
   c. **Gate:** require `email_verified` **and** `domain(email) ∈ tenant.allowed_email_domains`.
      On failure: redirect to `/login` with a clear "use your company email" flash; create nothing.
   d. **Upsert agent** in `TenantRepo` by email: set `is_sales_agent: true`, fill name, `active`.
      Refuse if an existing agent is `active: false`.
   e. **Upsert credential** (`provider`, `purpose: :agent_calendar`, tokens, scopes, `expires_at`).
   f. `log_in_agent` (renew session, store `agent_id`) → redirect to `/t/<slug>/calendar`.

---

## Merged calendar

- **Sync:** the existing per-tenant `CalendarSync` job (cron every 30 min) becomes
  provider-aware. For each agent with an `:agent_calendar` credential, it picks the impl by
  `cred.provider`, fetches the day's events, and **upserts all of them into `calendar_events`**.
  Client-matched events continue to derive/update `Visit` rows (+ Pipedrive deal resolution on
  new visits) exactly as today — now sourced from `calendar_events`.
- **View:** a new LiveView at `/t/<slug>/calendar` reads `calendar_events` for the tenant and
  renders a week/day grid of **all** agents' appointments, filterable by agent (and visually
  distinguished per agent). Reuses the calendar UI direction from
  [the calendar screen design](2026-05-26-calendar-screen-design.md).
- **Privacy note:** events come from agents' **work** calendars (they consented at sign-in).
  Default shows full event detail to the manager view; a "busy-only" detail toggle is a possible
  later refinement, not in this slice.

---

## OAuth app registration (operational)

**Decision: one central Florina app per provider** (one Google Cloud OAuth client, one Azure /
Entra **multi-tenant** app). Every customer's agents authorize the same app; tokens are stored
per tenant. Caveats planned around:

- Google requires **app verification** for the calendar scope (sensitive scope review/branding).
- Some Microsoft customers' IT may require a one-time **admin consent** for the app.

The schema also supports the **fallback**: a customer registers their own app and provides
`client_id` / `client_secret` (stored per credential, secret encrypted), used instead of the
central app. Start central; fall back per-customer only for a customer who needs it.

### Config / secrets

| Env var | Maps to | Notes |
|---|---|---|
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | existing | central Google app |
| `GOOGLE_REDIRECT_BASE` (opt) | existing | callback base; falls back to `PHX_HOST` |
| `MICROSOFT_CLIENT_ID` / `MICROSOFT_CLIENT_SECRET` | new | central Azure app |
| `MICROSOFT_TENANT` (opt, default `common`) | new | `common`/`organizations`/a tenant id |
| `MICROSOFT_REDIRECT_BASE` (opt) | new | callback base; falls back to `PHX_HOST` |

Config defaults `nil` in `config.exs`; real values from env in `runtime.exs` (mirrors Google).

---

## Security

- Tokens (`access_token`, `refresh_token`, per-customer `client_secret`) encrypted at rest via
  the existing Cloak vault (`Florina.Encrypted.*`).
- Signed, expiring OAuth `state` (tenant + provider + nonce). Reject mismatched provider.
- Require `email_verified` from the provider **and** a domain allow-list match — both, not either.
- Session renewed on login; `delete /logout` clears it.
- Inactive agents (`active: false`) cannot sign in even with a valid company email.
- Callback creates nothing on a failed gate (no half-provisioned accounts).

---

## Testing (local only; `test/` is git-ignored)

- Provider stubs for `OAuthProvider` / `CalendarProvider` (process-dict, like the existing
  `GoogleCalendar.Stub`), selected via app config in `test.exs`.
- `TenantCase` for per-tenant DB; `Oban.Testing` for the sync job.
- Cases: domain-gate accept/reject; `email_verified == false` reject; auto-approve creates agent
  + credential; second sign-in (other provider, same email) attaches a second credential to the
  same agent; inactive-agent refusal; `calendar_events` idempotent upsert; merged view shows
  multiple agents; provider dispatch picks the right impl.

---

## Phased delivery (login + calendar first)

- **Slice 1 — Sign in with Google.** Provider behaviours; `oauth_credentials` +
  `calendar_events` migrations; `allowed_email_domains` + agent `active`; `AgentAuth` + routes;
  `/login` page; Google adapted to behaviours; gate + auto-approve; move agent pages behind
  agent login; admin form gains allowed-domains. (Reuses most existing Google code.)
- **Slice 2 — Sign in with Microsoft.** Microsoft identity + Graph calendar impls; second button;
  same gate/flow.
- **Slice 3 — Merged calendar.** Provider-aware sync into `calendar_events`; the all-agents
  calendar LiveView.
- **Slice 4 — Florina's mailbox (Phase 2).** `MailProvider` (Gmail send / Graph `sendMail`);
  operator connects one `:florina_mailbox` credential per tenant; a `deliver/2` entry point.
  *What/when Florina emails is a separate, later design.*

---

## Out of scope (recorded)

- What/when Florina actually emails (triggers, templates) — Phase-2-follow-up design.
- Real-time calendar push (Google watches / Graph subscriptions) — cron suffices initially.
- A generic `/login` that routes to a tenant by email domain — agents use their company's URL.
- Two-way calendar write-back — read-only, as today.
