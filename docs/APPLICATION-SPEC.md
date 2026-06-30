# Florina (Elixir/Phoenix) — Application Specification

**Purpose:** a complete, self-contained description of the application — its architecture, data model, auth, background jobs, integrations, and the invariants it upholds. This is the architecture reference for the codebase.

- **Repo:** `florina-elixir` (sandbox fork `alexandruradulescu-neurony/florina-elixir`); work happens on `develop`.
- **Run locally:** `mix setup` then `mix phx.server` (http://localhost:4000). Postgres connects as the local OS user, no password, in dev.
- **Quality gate:** `mix precommit` = `compile --warnings-as-errors` + `deps.unlock --unused` + `format` + `test`.
- **Tests are git-ignored** (the `test/` tree is intentionally not committed). CI (`.github/workflows/ci.yml`) runs compile + format + unused-deps only — not the test suite.
- **Secrets:** a local, git-ignored `.env` holds the API keys; the git repo itself is clean of secrets (`.env` is untracked, ignored, and never in history).

---

## 1. Product overview

Florina is an AI sales-assistant SaaS, delivered as a **multi-tenant** Phoenix application (a clean-room Elixir re-implementation of a prior Django app; the Django code is reference-only and is never connected at runtime). Core capabilities:

- **Outbound AI voice calls** before/after sales meetings (via ElevenLabs Conversational AI over a Twilio bridge), with LLM-assembled call prompts.
- **LLM prompt assembly + post-call lessons distillation** (Anthropic Claude).
- **Calendar sync** (Google + Microsoft) that turns meetings into "visits" and drives call scheduling; plus a merged all-agents calendar view.
- **CRM sync** (per-tenant: Pipedrive or HubSpot) to enrich client records.
- **Agent self-service sign-in** (Google/Microsoft SSO), gated by per-company email domain.
- **Operator admin console** to manage tenants and publish central configuration.

Each customer ("tenant") is isolated in its own **Postgres schema** (`tenant_<id>`) on a single shared database, selected per request/job via the Ecto query prefix. A central "control-plane" schema holds the tenant registry, operator admins, and the canonical configuration that is published down to tenants.

---

## 2. Tech stack

- **Elixir** `~> 1.15` (CI/Docker on 1.18 / OTP 28), **Phoenix** `~> 1.8.8`, **LiveView** `~> 1.2`.
- **Bandit** HTTP server. **Ecto/Postgres** (`ecto_sql ~> 3.13`, `postgrex` unpinned `>= 0.0.0`).
- **Oban** `~> 2.18` (Postgres-backed background jobs, cron).
- **Cloak / cloak_ecto** (AES-GCM-256 field encryption at rest).
- **bcrypt_elixir** `~> 3.0` (admin passwords).
- **Req** `~> 0.5` (all outbound HTTP). **Swoosh** `~> 1.16` (mail; Local adapter, effectively unused).
- Deploy: **Railway** (Docker multi-stage; TLS terminated by Railway's proxy; `force_ssl` via `x-forwarded-proto`).

---

## 3. Architecture — multitenancy

### One database, one pool, schema-per-tenant
There is exactly **one** Postgres database and **one** connection pool, `Florina.Repo` — the only entry in `:ecto_repos`, so `mix ecto.migrate` / `Release.migrate/0` apply the **control-plane** migrations (`priv/repo/migrations/`). The control-plane schema (`public`) owns: `tenants`, `admins`, `oban_jobs` (+ Oban support tables), and the **canonical** central-config tables.

`Florina.TenantRepo` is a thin proxy over `Florina.Repo`: every query it runs is given `prefix: Process.get(:tenant_prefix)`, so it lands in that tenant's schema. With **no** pinned prefix it **fails closed** — `TenantRepo.*` raises rather than silently reading the wrong schema. All per-tenant contexts use only `TenantRepo`. In prod, Oban jobs check out connections from a dedicated jobs pool (pinned via `:tenant_repo`) so job load can't starve web requests; both pools point at the same database.

### Tenant resolution (request → pinned schema prefix)
- HTTP: `FlorinaWeb.Plugs.ResolveTenant` resolves the slug from the path param `/t/:tenant_slug` (primary) or subdomain (fallback), loads the control-plane `Tenant`, **requires `active: true` and `status: "active"`**, pins `Process.put(:tenant_prefix, "tenant_<id>")`, assigns `:tenant`, and registers a before-send callback that **clears the prefix** when the response is sent (so a pooled process can't carry it into a later, unrelated request). **Fails closed** (404 + halt) on any miss.
- The `:tenant_session` pipeline then writes `tenant.slug` into the session so LiveView can re-resolve on the socket.
- LiveView: `FlorinaWeb.TenantHook` (`on_mount`) re-resolves from `session["tenant_slug"]`, same accessibility check, pins the prefix, assigns `:tenant`. Fails closed (halt + redirect "/").
- The schema name is derived from the tenant's immutable **id** (`Tenants.schema_prefix/1` → `tenant_<id>`), never the mutable slug.

### Provisioning
`Florina.Tenants.Provisioner.provision/1` (idempotent): register control-plane row → `CREATE SCHEMA IF NOT EXISTS "tenant_<id>"` → run per-tenant migrations into that schema → seed central config. Pieces:
- `Migrator.migrate_one/all` runs `priv/tenant_repo/migrations/` against `Florina.Repo` with `prefix: "tenant_<id>"`; each schema keeps its own `schema_migrations` table. On prod boot, `Florina.Tenants.BootMigrator` applies pending tenant migrations to every active tenant before Oban/Endpoint start (blocking, fail-loud, isolating a single tenant's failure).
- `Florina.Workers.ProvisionTenant` (Oban) wraps it for the admin UI; sets status `active`/`failed`.

### Isolation invariants
- No cross-tenant reads: `TenantRepo` queries are scoped to the pinned schema prefix, and with no prefix they raise (fail closed) rather than hit a default schema.
- The prefix is process-local (`:tenant_prefix` in the process dictionary); no global "current tenant"; each web request and each Oban job pins independently and clears on completion.
- An agent session is bound to its login tenant (`:agent_tenant_slug`); `AgentAuth` rejects when it differs from the pinned tenant.
- A tenant with `active != true` (or `status != "active"`) is refused at the gate and excluded from cron fan-out (`Tenants.list_active/0`).
- **Shared, by design:** the Cloak encryption key is one per environment, shared across all tenants; the Oban jobs table (with tenant slugs in args) lives in the control-plane (`public`) schema; all tenant schemas share one Postgres database + role.

---

## 4. Data model

Custom timestamp convention on most `voice_*` schemas: `@timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]`. A few tables have only `created_at` or a single `timestamp`/`updated_at`. `admins` and `tenant_markers` use default `inserted_at/updated_at`.

### Control-plane (`Florina.Repo`)
| Table | Module | Notable |
|---|---|---|
| `tenants` | `Florina.Tenants.Tenant` | `slug` (unique), `active` (bool), `status` (`provisioning\|active\|failed`, app-validated only, no DB CHECK), `allowed_email_domains` (text[], lowercased/trimmed). Data isolated by Postgres schema `tenant_<id>` — no per-tenant database column. |
| `admins` | `Florina.Admins.Admin` | `email` (unique), `hashed_password` (bcrypt), `password` virtual |
| `voice_methodology` | `CentralConfig.Methodology` | canonical; `created_by_id` is a plain bigint (NO FK here) |
| `voice_scenario` | `CentralConfig.Scenario` | `name` + `slug` unique |
| `voice_megaprompt` | `CentralConfig.MegaPrompt` | enum `domain` (PRE_CALL/POST_CALL/LESSONS_DISTILL); unique `(domain,version)`; partial unique one-active-per-domain |
| `voice_globalsettings` | `CentralConfig.GlobalSettings` | singleton id=1 (app-enforced); call offsets, `max_call_attempts_per_phase`, `max_context_tokens_warn`, `default_methodology_id` FK |
| `oban_jobs` (+ peers/producers) | Oban | created via `Oban.Migration.up(version: 14)` |
| `voice_callattempt` | — | **dev/test mirror only**; created in control-plane migrations with `create_if_not_exists` (orphan table in a prod control-plane DB) |

### Per-tenant (`Florina.TenantRepo`)
| Table | Module | Notable |
|---|---|---|
| `tenant_markers` | `Tenants.Marker` | diagnostic / isolation-proof scaffolding |
| `voice_user` | `Accounts.User` | the "agent"; `username` unique, `email`, `is_sales_agent`, `active`, `role` (`manager\|agent`); circular FK with methodology |
| `voice_methodology` | `Methodologies.Methodology` | per-tenant copy; `is_overridden`; `created_by_id` → voice_user (nilify) |
| `voice_client` | `Clients.Client` | `crm_id` unique; `domain` indexed; `status` enum stored in **Romanian** (`new:"nou"`, `existing:"existent"`); free-form jsonb `contacts/deal_history/interaction_history` |
| `voice_scenario` | `Scenarios.Scenario` | per-tenant copy; `is_overridden` |
| `voice_visit` | `Visits.Visit` | central entity; FKs `agent_id`/`client_id` **ON DELETE CASCADE**, methodology/scenario nilify; enum `status` (lifecycle PLANNED→PRE_CALL_DONE→IN_PROGRESS→POST_CALL_DONE→COMPLETE, plus terminal CANCELLED / MISSED / ARCHIVED); `calls_enabled`; per-phase prompt + lock fields; `calendar_event_id`, `crm_deal_id` |
| `voice_callattempt` | `Calls.CallAttempt` | FK `visit_id` cascade; `status` (SCHEDULED/INITIATED/IN_PROGRESS/COMPLETED/NO_ANSWER/FAILED) |
| `voice_megaprompt` | `Prompts.MegaPrompt` | per-tenant copy; same unique constraints as canonical |
| `voice_generationrun` | `Prompts.GenerationRun` | LLM audit; **encrypted** `context_bundle`/`parsed_outputs` (Encrypted.Map), `claude_request`/`claude_response`/`error` (Encrypted.Binary); `mega_prompt_id` is the **only ON DELETE RESTRICT** FK; visit/client cascade |
| `voice_globalsettings` | `Settings.GlobalSettings` | per-tenant copy; `is_overridden`; per-tenant CRM creds (`crm_provider`, encrypted `pipedrive_api_token`/`hubspot_api_token`, `pipedrive_domain`) |
| `voice_activitylog` | `Audit.ActivityLog` | nilify FKs (audit survives deletes); `level` enum |
| `voice_googlecalendarwatch` | `Calendar.GoogleCalendarWatch` | push-watch table, unused by the current poll-based sync; `channel_id` unique |
| `oauth_credentials` | `OAuth.Credential` | unified per-agent OAuth; enums `provider`(google/microsoft) + `purpose`(agent_calendar/florina_mailbox); **encrypted** `access_token`/`refresh_token`/`client_secret`; `client_id` **plaintext**; partial unique `(provider,purpose,user_id)` covering nullable `user_id` |
| `calendar_events` | `Calendar.Event` | merged-calendar source; enum `provider`; unique `(user_id,provider,external_event_id)`; `raw` jsonb; user_id cascade |

Per-tenant migrations live in `priv/tenant_repo/migrations/` — a squashed pure-DSL baseline (`tenant_baseline`) where encrypted columns are `:binary` from the start, plus incremental migrations on top.

---

## 5. Web layer & auth

### Endpoint plug chain
Static → RequestId → Telemetry → Parsers (**custom `RawBodyReader` caches the raw body** for webhook HMAC) → MethodOverride → Head → **Session (cookie, signed, `SameSite=Lax`, NOT encrypted)** → Router.

### Pipelines
`:browser` (session+CSRF+secure headers), `:webhook` (json only), `:resolve_tenant` (ResolveTenant plug), `:tenant_session` (write slug to session), `:agent_auth` (`fetch_current_agent` + `require_authenticated_agent`), `:require_admin` (RequireAdmin plug).

### Routes (summary)
- `POST /t/:slug/webhooks/elevenlabs` — `[:webhook, :resolve_tenant]` — HMAC-verified inbound.
- `GET /` — public landing. `GET /healthz` — no pipeline, plain "ok".
- `GET /login` + `GET /auth/:provider/start` — **global one-click sign-in**: no tenant in the URL; the workspace is auto-detected from the verified email's domain during the callback.
- `GET /t/:slug/login`, `GET /t/:slug/auth/:provider/start`, `DELETE /t/:slug/logout` — `[:browser, :resolve_tenant, :tenant_session]` (no agent gate — these establish the session).
- `GET /auth/:provider/callback` — `[:browser]` only, **not** tenant-scoped: one redirect URI per provider; the tenant is recovered from the signed `state` (slug) or the verified email's domain, then pinned in the controller.
- `LIVE /t/:slug/...` (manager dashboard/meetings/clients/people/methodologies/mega-prompts/runs/settings/logs/chat, agent today/call-me/clients, shared calendar) — `[:browser, :resolve_tenant, :tenant_session, :agent_auth]` (agent-gated; chat is `TenantChatLive`).
- `GET/POST /admin/login`, `DELETE /admin/logout` — `[:browser]`. `LIVE /admin | /admin/tenants | /admin/agents | /admin/config` — `[:browser, :require_admin]`.

### Two auth mechanisms
1. **Operator admin** — `Florina.Admins.authenticate/2` (bcrypt, timing-safe, dummy-verify on miss). HTTP guard `Plugs.RequireAdmin` (session `admin_id`); LiveView `Admin.AdminAuth` on_mount. Session renewed on login, dropped on logout. First admin seeded from `ADMIN_EMAIL`/`ADMIN_PASSWORD` at boot if `admins` empty. Login throttled per-email + per-IP by `Florina.Auth.LoginRateLimiter`.
2. **Agent SSO** — `FlorinaWeb.AuthController` + `FlorinaWeb.AgentAuth`. Sign-in callback security chain (`GET /auth/:provider/callback`, fixed path):
   1. provider ∈ `~w(google microsoft)` (else 400);
   2. **state verify** — `Phoenix.Token.verify` (salt `"agent_oauth_state"`, max_age 600s), plus a per-browser login-CSRF **nonce** match against the session; the payload carries the provider and an optional tenant slug;
   3. `exchange_code` (server-to-server TLS to the provider token endpoint);
   4. `fetch_identity` — decode id_token claims and validate **audience/issuer/expiry** (`Provider.verify_id_token/2`); Microsoft `email_verified` honors `xms_edov`; the signature is intentionally not re-verified (the token arrives over TLS directly from the token endpoint, OIDC §3.1.3.7);
   5. **resolve tenant** — from the state's slug when present, else from the verified email's domain (`Tenants.get_by_email_domain`); require `active`/`status active`; pin the prefix;
   6. **gate** — requires `email_verified == true` **AND** `domain(email) ∈ tenant.allowed_email_domains` (both lowercased); empty allow-list blocks all; creates nothing on failure;
   7. upsert agent (`Accounts.upsert_agent_from_identity`, refuses `active: false`);
   8. store encrypted calendar credential;
   9. `log_in_agent` — session renew + `agent_id` + sticky `agent_tenant_slug` → redirect into the tenant.

Agent LiveViews run `on_mount TenantHook` **then** `{AgentAuth, :ensure_authenticated}` (order matters — tenant pinned before agent lookup); manager-only screens add `{AgentAuth, :require_manager}`.

### Inbound webhook (ElevenLabs)
HMAC-SHA256 over `"{timestamp}.{raw_body}"`, header `t=..,v0=..`, `Plug.Crypto.secure_compare`, **±30-min freshness window**; missing secret → 503; bad sig → 401. On success → `Calls.apply_elevenlabs_webhook/2` (updates the CallAttempt + PubSub broadcast, and enqueues `PostCallCompletion` for a completed call).

---

## 6. Background jobs (Oban)

**Queues:** `default:10`, `scheduler:5`, `calls:5`, `sync:10`, `provisioning:2`. **Plugins:** Pruner (7-day), Cron. **Test:** `testing: :manual`.

**Cron (fan-out → per-tenant):** every 5 min `CallScheduler`→`ScanTenantCalls`; every 15 min `SyncPendingCallsScheduler`→`SyncPendingCalls`; every 5 min `CalendarSyncScheduler`→`CalendarSync`→`CalendarSyncAgent`; daily 00:05 `CrmSyncScheduler`→`CrmSync`. Schedulers enumerate `Tenants.list_active/0`; each unit worker first calls `Florina.Workers.Tenant.pin_active(slug)` (raises → Oban retry).

**Call lifecycle:** `CalendarSync` creates `Visit{:PLANNED}` when an event attendee-domain matches a client → `ScanTenantCalls` finds due visits (PRE offsets −60/−30 min, POST offsets +15/+30 min, ±5-min window, per-phase cap, skip if agent has no phone) and dispatches `DialCall` (idempotency guard on an existing non-FAILED attempt; resolves/assembles the prompt; creates `CallAttempt{SCHEDULED}`; calls ElevenLabs; on success INITIATED + advances the visit) → `SyncPendingCalls` polls ElevenLabs for stale in-flight attempts and maps status → `PostCallCompletion` runs the post-call pipeline (lessons distillation, visit → `:COMPLETE`) and writes the debrief back to the CRM. `ScanTenantCalls` also retires stale past visits: call-enabled ones to `:MISSED`, call-disabled ones to `:ARCHIVED`, so they drop off the active calendar.

`ProvisionTenant` (provisioning queue) creates a tenant end-to-end.

---

## 7. External integrations

Most external credentials are **global (shared across tenants)** via app config/env — **one** ElevenLabs account, **one** Anthropic key, and **one** OAuth app per provider. **CRM credentials are per-tenant** (each tenant's Pipedrive/HubSpot token + provider choice live encrypted in its `voice_globalsettings`; there is no global CRM fallback). Per-agent *user* OAuth tokens are per-tenant. Each integration uses a behaviour/config-swap so tests inject stubs (`:elevenlabs_client`, `:anthropic_client`, `:pipedrive_client`, `:oauth_provider_google`, `:oauth_provider_microsoft`).

- **ElevenLabs** (`integrations/eleven_labs.ex`) — `initiate_call` (POST twilio outbound-call with prompt override), `get_conversation`/`fetch_transcript` (multi-URL fallback for API-version drift). `receive_timeout: 30s`. Signature verify in `eleven_labs_signature.ex`.
- **Anthropic** (`anthropic.ex` + `anthropic/sse.ex`) — `stream_chat` (LiveView chat, SSE → `:on_delta`) and `complete` (blocking; Assembler/Lessons), both with explicit connect + `receive_timeout`. Model `claude-sonnet-4-6` (global). Key `ANTHROPIC_API_KEY`.
- **CRM** (`integrations/crm.ex` facade → `pipedrive.ex` | `hubspot.ex`, per-tenant `crm_provider`) — read org/deal/person/note/activity (paginated); `create_note` is Pipedrive-only (HubSpot's is a `:not_implemented` stub). Pipedrive auth via `x-api-token` **header** (kept out of URLs/logs); HubSpot via Bearer Private-App token. `receive_timeout: 15s`.
- **OAuth providers** — `Provider` dispatcher + shared helpers (redirect_uri, sign/verify state, decode/verify claims, `ensure_valid_token` with 60s skew, refresh persisted). `Providers.Google` (scopes openid/email/profile/calendar.readonly; `access_type=offline`, `prompt=consent`) + `Providers.Microsoft` (Graph; default `MICROSOFT_TENANT=organizations` = work/school only; `Calendars.Read`; `$top=250`, no pagination). Behaviours `OAuthProvider`/`CalendarProvider`.
- **ClientSync** (`integrations/client_sync.ex`) — Pipedrive → `voice_client` upsert + bounded enrichment (≤20 contacts/deals/interactions); per-org errors collected, sub-fetch failures swallowed to `[]`. Client domain derived from contacts' email domains.

---

## 8. Domain services & prompt-injection posture

- **Assembler** (`services/assembler.ex`) — loads the active `MegaPrompt`, builds context via `DataContext`, renders via `Placeholders`, calls `Anthropic.complete` (max_tokens 4096), parses/validates JSON (body ≤50k chars, first-message ≤2k; Romanian-quote repair fallback), writes prompts back to the visit (respecting lock flags), records a `GenerationRun` audit row. **Never raises** — failures are recorded as failed runs.
- **DataContext** (`services/data_context.ex`) — builds placeholder maps (agent/client/scenario/methodology + bounded history) and `build_chat_context/0` for grounded chat (≤20 clients, 10 visits, 5 calls). Must run with `TenantRepo` pinned.
- **VisitPipeline** (`services/visit_pipeline.ex`) — `process_pre_call`/`process_post_call` (status transitions), `extract_domain_from_email`, chains `Lessons.distill`.
- **Lessons** (`services/lessons.ex`) — LESSONS_DISTILL domain; updates `client.lessons_learned`.
- **Placeholders** (`services/placeholders.ex`) — **prompt-injection mitigations**: regex substitution (no format-string eval), untrusted fields fenced in `<FIELD> … </ FIELD>` tags (space-defanged close), values capped at 20k chars, backtick spans preserved for dial-time passthrough, placeholder regex excludes dots/brackets. The Assembler system prompt instructs the model to treat tagged blocks as inert data and to return JSON only.

---

## 9. Central config distribution
Canonical config lives in the control-plane (`CentralConfig`, `Florina.Repo`). On provision, `seed_tenant/1` copies canonical rows into the tenant **preserving ids**, skipping rows the tenant marked `is_overridden: true`, forcing seeded `is_overridden=false` (`insert_all on_conflict: :replace_all, conflict_target: :id`). `publish_to/1` upserts canonical → one tenant by id, excluding `:id`/`:is_overridden` from replace; `publish_all/0` iterates active tenants with per-tenant failure isolation. Per-tenant context edits set `is_overridden: true` so publishes don't clobber customisations. Effective value = tenant override ?? central default.

---

## 10. Security model & invariants
1. **Tenant data isolation** — a request/job for tenant A can never read/write tenant B's data (schema-per-tenant + process-local pinning + fail-closed resolution + login-tenant binding + `active` gate).
2. **Agent sign-in gate** — only a provider-verified email whose domain is in the tenant's allow-list can create/use an agent account; OAuth `state` is signed and bound to tenant+provider with a per-browser nonce; sessions renew on login.
3. **Webhook authenticity** — only HMAC-valid, fresh ElevenLabs webhooks are processed.
4. **Secrets at rest** — OAuth tokens, CRM tokens, and LLM audit payloads are AES-GCM encrypted; passwords are bcrypt.
5. **Prompt injection containment** — untrusted CRM/calendar/transcript text cannot escape its data fence to become model instructions.
6. **Config override safety** — publishing central config never overwrites a tenant's `is_overridden` customisations.
7. **Operator/agent separation** — `/admin/*` requires an operator admin session; agent pages require an agent session; the two are distinct.

---

## 11. Encryption at rest
`Florina.Vault` (`use Cloak.Vault`), single cipher AES-256-GCM (12-byte IV, tag `AES.GCM.V1`). Key: dev/test use a fixed key in `config/{dev,test}.exs` (identical); **prod requires `FIELD_ENCRYPTION_KEY`** (`runtime.exs` raises if missing). Custom Ecto types `Florina.Encrypted.Binary` (bytea) and `Florina.Encrypted.Map` (JSON→encrypted bytea). Vault starts in the supervision tree before any encrypted read.

---

## 12. Config, supervision & deploy
**Supervision order** (`application.ex`, one_for_one): Telemetry → **Vault** → **LoginRateLimiter** → **Repo** → **BootMigrator** (applies pending per-tenant migrations before Oban/Endpoint; prod only) → DNSCluster → PubSub → **Oban** → **Endpoint**; then `Admins.ensure_seed_from_env()` runs post-start (rescues all errors).

**Required at prod boot (raise if missing):** `FIELD_ENCRYPTION_KEY`, `DATABASE_URL`, `SECRET_KEY_BASE`. **Optional (feature silently degrades if absent):** global integration keys (`ANTHROPIC_API_KEY`, `ELEVENLABS_*`, `GOOGLE_*`, `MICROSOFT_*`), `OAUTH_REDIRECT_BASE`, `PHX_HOST`/`TENANT_BASE_HOST`, `POOL_SIZE`, `ECTO_IPV6`, `DNS_CLUSTER_QUERY`, `ADMIN_EMAIL`/`ADMIN_PASSWORD`. `ELEVENLABS_WEBHOOK_SECRET` is read in all envs. CRM credentials are per-tenant, entered in the UI — no global `PIPEDRIVE_*` env.

**Release ops** (`Florina.Release`): `migrate/0` (control-plane), `migrate_tenants/0` (all tenant schemas), `provision_tenant/3`, `create_admin/2`. `railway.json` `preDeployCommand` runs `bin/migrate` (control-plane) before traffic; per-tenant migrations auto-apply at boot in prod (`:migrate_tenants_on_boot`); `migrate_tenants/0` remains available for manual runs. Docker runs as `nobody`; `bin/server` sets `PHX_SERVER`.

---

## 13. File map (where to look)
- Tenancy: `lib/florina/repo.ex`, `lib/florina/tenant_repo.ex`, `lib/florina/tenants/` (`tenant.ex`, `provisioner.ex`, `migrator.ex`, `boot_migrator.ex`, `subdomain.ex`, `marker.ex`), `lib/florina/tenants.ex`.
- Web/auth: `lib/florina_web/router.ex`, `lib/florina_web/plugs/`, `lib/florina_web/agent_auth.ex`, `lib/florina_web/admin_auth.ex`, `lib/florina_web/tenant_hook.ex`, `lib/florina_web/controllers/` (auth, admin/session, webhook/eleven_labs, health), `lib/florina_web/live/`.
- Jobs: `lib/florina/workers/`. Config: `config/*.exs`. App: `lib/florina/application.ex`, `lib/florina/release.ex`.
- Integrations/services: `lib/florina/integrations/`, `lib/florina/services/`, `lib/florina/anthropic*`, `lib/florina/central_config.ex`, `lib/florina/oauth*`.
- Schemas: under each context dir in `lib/florina/`. Migrations: `priv/repo/migrations/` (control-plane), `priv/tenant_repo/migrations/` (per-tenant).
- Encryption: `lib/florina/vault.ex`, `lib/florina/encrypted/`.
- Deploy: `Dockerfile`, `railway.json`, `rel/overlays/bin/`, `mix.exs`, `.github/workflows/ci.yml`.
