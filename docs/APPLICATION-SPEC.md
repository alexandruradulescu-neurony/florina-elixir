# Florina (Elixir/Phoenix) — Application Specification

**Purpose of this document:** a complete, self-contained description of the application for an **adversarial code review** by external tools (e.g. Codex, Gemini). It describes the architecture, data model, auth, jobs, integrations, and the **invariants the system claims to uphold**, then lists **areas flagged for scrutiny**. Reviewers have the source; treat every "flagged" item as a *hypothesis to confirm or refute against the code*, not as established fact.

- **Repo:** `florina-elixir` (sandbox fork `alexandruradulescu-neurony/florina-elixir`). Review the **`develop`** branch.
- **Run locally:** `mix setup` then `mix phx.server` (http://localhost:4000). Postgres connects as the local OS user, no password, in dev.
- **Quality gate:** `mix precommit` = `compile --warnings-as-errors` + `deps.unlock --unused` + `format` + `test`.
- **Tests are git-ignored** (the `test/` tree is intentionally not committed). CI (`.github/workflows/ci.yml`) runs compile + format + unused-deps only — **not** the test suite.
- **Do not upload the working directory wholesale to a third party:** a local, git-ignored `.env` holds real API keys. The git repo itself is clean of secrets (verified: `.env` untracked, ignored, never in history). Review from the repo, not a folder zip.

---

## 1. Product overview

Florina is an AI sales-assistant SaaS, delivered as a **multi-tenant** Phoenix application (a clean-room Elixir re-implementation of a prior Django app; the Django code is reference-only and is never connected at runtime). Core capabilities:

- **Outbound AI voice calls** before/after sales meetings (via ElevenLabs Conversational AI over a Twilio bridge), with LLM-assembled call prompts.
- **LLM prompt assembly + post-call lessons distillation** (Anthropic Claude).
- **Calendar sync** (Google + Microsoft) that turns meetings into "visits" and drives call scheduling; plus a merged all-agents calendar view.
- **CRM sync** (Pipedrive) to enrich client records.
- **Agent self-service sign-in** (Google/Microsoft SSO), gated by per-company email domain.
- **Operator admin console** to manage tenants and publish central configuration.

Each customer ("tenant") is **physically isolated in its own Postgres database**. A central "control-plane" database holds the tenant registry, operator admins, and the canonical configuration that is published down to tenants.

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

### Two repos
- **`Florina.Repo`** — the fixed **control-plane** database. The *only* entry in `:ecto_repos`, so `mix ecto.migrate` and `Release.migrate/0` touch only this DB. Owns: `tenants`, `admins`, `oban_jobs` (+ Oban support tables), and the **canonical** central-config tables.
- **`Florina.TenantRepo`** — a **dynamic** repo with *no* compile-time database, deliberately omitted from `:ecto_repos`. Every process that touches tenant data must first call `Florina.TenantRepo.put_dynamic_repo(pid)` to bind itself (process-dictionary local) to a specific tenant pool. With no binding, any `TenantRepo.*` query fails. All per-tenant contexts use only `TenantRepo`.

### Connection manager
`Florina.Tenants.ConnectionManager` (GenServer singleton, started before the Endpoint) keeps a `slug => pid` map of live `TenantRepo` pools (one `DBConnection` pool per tenant per node, `tenant_pool_size` default **2**). `ensure_started(slug)` returns a cached live pid, restarts a dead one, or starts a new pool from the control-plane tenant row. Individual tenant pools are **not** independently supervised — a pool crash is detected only on the next `ensure_started`.

### Tenant resolution (request → pinned repo)
- HTTP: `FlorinaWeb.Plugs.ResolveTenant` resolves the slug from the path param `/t/:tenant_slug` (primary) or subdomain (fallback), loads the control-plane `Tenant`, **requires `active: true`**, calls `ConnectionManager.ensure_started`, pins `TenantRepo`, assigns `:tenant`. **Fails closed** (404 + halt) on any miss.
- The `:tenant_session` pipeline then writes `tenant.slug` into the session so LiveView can re-resolve on the socket.
- LiveView: `FlorinaWeb.TenantHook` (`on_mount`) re-resolves from `session["tenant_slug"]`, same `active: true` check, pins the repo, assigns `:tenant`. Fails closed (halt + redirect "/").

### Provisioning
`Florina.Tenants.Provisioner.provision/1` (idempotent): create DB → register control-plane row → start pool → run per-tenant migrations → seed central config. Pieces:
- `DatabaseProvisioner` behaviour (config-selected; default `SamePostgres` uses `Ecto.Adapters.Postgres.storage_up/down` on the same server) — **swappable** to move tenant DBs elsewhere.
- `ConnectionOpts` parses the control-plane config / `DATABASE_URL` into per-tenant pool opts and into discrete params for `storage_up`.
- `Migrator.migrate_one/all` runs `priv/tenant_repo/migrations/` against each tenant via `dynamic_repo:`.
- `Florina.Workers.ProvisionTenant` (Oban) wraps it for the admin UI; sets status `active`/`failed`.

### Isolation invariants (claims to attack)
- No cross-tenant FK/joins possible (separate physical DBs).
- `put_dynamic_repo` is process-local; no global "current tenant"; each web request and each Oban job pins independently.
- A tenant with `active != true` (or `status != "active"`) is refused at the gate and excluded from cron fan-out (`Tenants.list_active/0`).
- **Not isolated:** the Cloak encryption key is **one per environment**, shared across all tenants; the Oban jobs table (with tenant slugs in args) lives in the control-plane DB; all tenant DBs share one Postgres server + role (the app role has `CREATEDB`).

---

## 4. Data model

Custom timestamp convention on most `voice_*` schemas: `@timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]`. A few tables have only `created_at` or a single `timestamp`/`updated_at`. `admins` and `tenant_markers` use default `inserted_at/updated_at`.

### Control-plane (`Florina.Repo`)
| Table | Module | Notable |
|---|---|---|
| `tenants` | `Florina.Tenants.Tenant` | `slug` (unique), `database`, `active` (bool), `status` (`provisioning\|active\|failed`, app-validated only, no DB CHECK), `allowed_email_domains` (text[], lowercased/trimmed) |
| `admins` | `Florina.Admins.Admin` | `email` (unique), `hashed_password` (bcrypt), `password` virtual |
| `voice_methodology` | `CentralConfig.Methodology` | canonical; `created_by_id` is a plain bigint (NO FK here) |
| `voice_scenario` | `CentralConfig.Scenario` | `name` + `slug` unique |
| `voice_voiceprompt` | `CentralConfig.VoicePrompt` | enum `prompt_type` (PRE/POST); partial unique `(prompt_type) WHERE is_active` |
| `voice_megaprompt` | `CentralConfig.MegaPrompt` | enum `domain` (PRE_CALL/POST_CALL/LESSONS_DISTILL); unique `(domain,version)`; partial unique one-active-per-domain |
| `voice_globalsettings` | `CentralConfig.GlobalSettings` | singleton id=1 (app-enforced); offsets, `max_context_tokens_warn`, `default_methodology_id` FK |
| `oban_jobs` (+ peers/producers) | Oban | created via `Oban.Migration.up(version: 14)` |
| `voice_callattempt` | — | **dev/test mirror only**; created in control-plane migrations with `create_if_not_exists` (flag: orphan table in a prod control-plane DB) |

### Per-tenant (`Florina.TenantRepo`)
| Table | Module | Notable |
|---|---|---|
| `tenant_markers` | `Tenants.Marker` | diagnostic/isolation-proof scaffolding ("remove once real consumers wired" — still present) |
| `voice_user` | `Accounts.User` | the "agent"; `username` unique, `email`, `is_sales_agent`, `active`; circular FK with methodology |
| `voice_methodology` | `Methodologies.Methodology` | per-tenant copy; `is_overridden`; `created_by_id` → voice_user (nilify) |
| `voice_client` | `Clients.Client` | `crm_id` unique; `domain` indexed; `status` enum stored in **Romanian** (`new:"nou"`, `existing:"existent"`); free-form jsonb `contacts/deal_history/interaction_history` |
| `voice_scenario` | `Scenarios.Scenario` | per-tenant copy; `is_overridden` |
| `voice_visit` | `Visits.Visit` | central entity; FKs `agent_id`/`client_id` **ON DELETE CASCADE**, methodology/scenario nilify; enum `status` (PLANNED→PRE_CALL_DONE→IN_PROGRESS→POST_CALL_DONE→COMPLETE); per-phase prompt + lock fields; `calendar_event_id`, `crm_deal_id` |
| `voice_callattempt` | `Calls.CallAttempt` | FK `visit_id` cascade; `status` (SCHEDULED/INITIATED/IN_PROGRESS/COMPLETED/NO_ANSWER/FAILED); **several DB columns not mapped in the schema** (`scheduled_offset_minutes`, `scheduled_time`, `executed_at`, `retry_count`) |
| `voice_voiceprompt` | `Calls.VoicePrompt` | per-tenant copy; partial unique active-per-type |
| `voice_megaprompt` | `Prompts.MegaPrompt` | per-tenant copy; same unique constraints as canonical |
| `voice_generationrun` | `Prompts.GenerationRun` | LLM audit; **encrypted** `context_bundle`/`parsed_outputs` (Encrypted.Map), `claude_request`/`claude_response`/`error` (Encrypted.Binary); `mega_prompt_id` is the **only ON DELETE RESTRICT** FK; visit/client cascade |
| `voice_globalsettings` | `Settings.GlobalSettings` | per-tenant copy; `is_overridden` |
| `voice_activitylog` | `Audit.ActivityLog` | nilify FKs (audit survives deletes); `level` enum |
| `voice_googlecalendarwatch` | `Calendar.GoogleCalendarWatch` | push-watch (legacy; not used by current sync); `channel_id` unique |
| `oauth_credentials` | `OAuth.Credential` | unified per-agent OAuth; enums `provider`(google/microsoft) + `purpose`(agent_calendar/florina_mailbox); **encrypted** `access_token`/`refresh_token`/`client_secret`; `client_id` **plaintext**; unique `(provider,purpose,user_id)`; `user_id` nullable (mailbox future) |
| `calendar_events` | `Calendar.Event` | merged-calendar source; enum `provider`; unique `(user_id,provider,external_event_id)`; `raw` jsonb; user_id cascade |

Per-tenant migration order is in `priv/tenant_repo/migrations/` (note `encrypt_sensitive_fields` converts text/jsonb→bytea; `drop_voice_googleoauthcredential` retires the old Google-only table now replaced by `oauth_credentials`).

---

## 5. Web layer & auth

### Endpoint plug chain
Static → RequestId → Telemetry → Parsers (**custom `RawBodyReader` caches the raw body** for webhook HMAC) → MethodOverride → Head → **Session (cookie, signed, `SameSite=Lax`, NOT encrypted)** → Router.

### Pipelines
`:browser` (session+CSRF+secure headers), `:webhook` (json only), `:resolve_tenant` (ResolveTenant plug), `:tenant_session` (write slug to session), `:agent_auth` (`fetch_current_agent` + `require_authenticated_agent`), `:require_admin` (RequireAdmin plug), `:dashboard_auth` (shared Basic-Auth from `:florina, :dashboard_auth`).

### Routes (summary)
- `POST /t/:slug/webhooks/elevenlabs` — `[:webhook, :resolve_tenant]` — HMAC-verified inbound.
- `GET /` — home. `GET /healthz` — no pipeline, plain "ok".
- `GET /t/:slug/login`, `GET /t/:slug/auth/:provider/start`, `GET /t/:slug/auth/:provider/callback`, `DELETE /t/:slug/logout` — `[:browser, :resolve_tenant, :tenant_session]` (no agent gate — these establish the session).
- `LIVE /t/:slug/calls | /chat | /calendar` — `[:browser, :resolve_tenant, :tenant_session, :agent_auth]` (agent-gated).
- `LIVE /chat` (global demo `ChatLive`) — `[:browser, :dashboard_auth]`.
- `GET/POST /admin/login`, `DELETE /admin/logout` — `[:browser]`. `LIVE /admin | /admin/tenants | /admin/config` — `[:browser, :require_admin]`.
- `GET /t/:slug/whoami` — `[:browser, :resolve_tenant]` (diagnostic; **no auth**).

### Three auth mechanisms
1. **Operator admin** — `Florina.Admins.authenticate/2` (bcrypt, timing-safe, dummy-verify on miss). HTTP guard `Plugs.RequireAdmin` (session `admin_id`); LiveView `Admin.AdminAuth` on_mount. Session renewed on login, dropped on logout. First admin seeded from `ADMIN_EMAIL`/`ADMIN_PASSWORD` at boot if `admins` empty.
2. **Shared dashboard Basic-Auth** — gates the global `/chat` demo only (`DASHBOARD_USER`/`DASHBOARD_PASS`).
3. **Agent SSO** — `FlorinaWeb.AuthController` + `FlorinaWeb.AgentAuth`. Sign-in callback security chain (`/t/:slug/auth/:provider/callback`):
   1. tenant resolved (`active: true`) and pinned;
   2. provider ∈ `~w(google microsoft)` (else 400);
   3. **state verify** — `Phoenix.Token.verify` (salt `"agent_oauth_state"`, max_age 600s); payload pattern-pinned to **both** `^tenant_slug` and `^provider` (rejects cross-tenant/provider replay);
   4. `exchange_code` (server-to-server TLS to provider token endpoint);
   5. `fetch_identity` (decode id_token claims — *not* re-verified; safe because token came from the TLS token endpoint, not the browser);
   6. **gate** — requires `email_verified == true` **AND** `domain(email) ∈ tenant.allowed_email_domains` (both lowercased); empty allow-list blocks all; creates nothing on failure;
   7. upsert agent (`Accounts.upsert_agent_from_identity`, refuses `active: false`);
   8. store encrypted calendar credential;
   9. `log_in_agent` — session renew + `agent_id` → redirect `/t/:slug/calendar`.

LiveViews `CallsLive`/`TenantChatLive`/`CalendarLive` run `on_mount TenantHook` **then** `{AgentAuth, :ensure_authenticated}` (order matters — tenant pinned before agent lookup).

### Inbound webhook (ElevenLabs)
HMAC-SHA256 over `"{timestamp}.{raw_body}"`, header `t=..,v0=..`, `Plug.Crypto.secure_compare`, **±30-min freshness window**; missing secret → 503; bad sig → 401. On success → `Calls.apply_elevenlabs_webhook/2` (updates the CallAttempt + PubSub broadcast).

---

## 6. Background jobs (Oban)

**Queues:** `default:10`, `scheduler:5`, `calls:5`, `sync:10`, `provisioning:2`. **Plugins:** Pruner (7-day), Cron. **Test:** `testing: :manual`.

**Cron (fan-out → per-tenant):** every 5 min `CallScheduler`→`ScanTenantCalls`; every 15 min `SyncPendingCallsScheduler`→`SyncPendingCalls`; every 30 min `CalendarSyncScheduler`→`CalendarSync`; daily 00:05 `CrmSyncScheduler`→`CrmSync`. Schedulers enumerate `Tenants.list_active/0`; each unit worker first calls `Florina.Workers.Tenant.pin!(slug)` (raises → Oban retry).

**Call lifecycle:** `CalendarSync` creates `Visit{:PLANNED}` when an event attendee-domain matches a client → `ScanTenantCalls` finds due visits (PRE offsets −60/−30 min, POST offsets +15/+30 min, ±5-min window, cap 2 dials/phase, skip if agent has no phone) → `DialCall` (idempotency guard on existing non-FAILED attempt; resolves/assembles prompt; creates `CallAttempt{SCHEDULED}`; calls ElevenLabs; on success INITIATED + advance visit) → `SyncPendingCalls` polls ElevenLabs for stale in-flight attempts and maps status. Visit status machine: PLANNED→PRE_CALL_DONE→IN_PROGRESS→POST_CALL_DONE→COMPLETE.

`ProvisionTenant` (provisioning queue) creates a tenant end-to-end. `PostCallCompletion` exists (would run the post-call pipeline → `:COMPLETE`) — **see flagged items: it appears to have no enqueue site**.

---

## 7. External integrations

All external credentials are **global (shared across tenants)** via app config/env — there is **one** ElevenLabs account, **one** Anthropic key, **one** Pipedrive token, and **one** OAuth app per provider. Per-agent *user* tokens are per-tenant. Each integration uses a behaviour/config-swap so tests inject stubs (`:elevenlabs_client`, `:anthropic_client`, `:pipedrive_client`, `:oauth_provider_google`, `:oauth_provider_microsoft`).

- **ElevenLabs** (`integrations/eleven_labs.ex`) — `initiate_call` (POST twilio outbound-call with prompt override), `get_conversation`/`fetch_transcript` (multi-URL fallback for API-version drift). `receive_timeout: 30s`. Signature verify in `eleven_labs_signature.ex`.
- **Anthropic** (`anthropic.ex` + `anthropic/sse.ex`) — `stream_chat` (LiveView chat, SSE → `:on_delta`) and `complete` (blocking; Assembler/Lessons). Model `claude-sonnet-4-6` (global). Key `ANTHROPIC_API_KEY`.
- **Pipedrive** (`integrations/pipedrive.ex`) — read org/deal/person/note/activity (paginated), `create_note` (write). Auth via `api_token` **query param**. `receive_timeout: 15–30s`.
- **OAuth providers** — `Provider` dispatcher + shared helpers (redirect_uri, sign/verify state, decode_claims, `ensure_valid_token` with 60s skew). `Providers.Google` (scopes openid/email/profile/calendar.readonly; `access_type=offline`, `prompt=consent`) + `Providers.Microsoft` (Graph; default `MICROSOFT_TENANT=organizations` = work/school only; `Calendars.Read`; `$top=250`, no pagination). Behaviours `OAuthProvider`/`CalendarProvider`.
- **ClientSync** (`integrations/client_sync.ex`) — Pipedrive → `voice_client` upsert + bounded enrichment (≤20 contacts/deals/interactions); per-org errors collected, sub-fetch failures swallowed to `[]`. Client domain derived from Pipedrive `cc_email`.

---

## 8. Domain services & prompt-injection posture

- **Assembler** (`services/assembler.ex`) — loads active `MegaPrompt`, builds context via `DataContext`, renders via `Placeholders`, calls `Anthropic.complete` (max_tokens 4096), parses/validates JSON (body ≤50k chars, first-message ≤2k; Romanian-quote repair fallback), writes prompts back to the visit (respecting lock flags), records a `GenerationRun` audit row. **Never raises** — failures recorded as failed runs.
- **DataContext** (`services/data_context.ex`) — builds placeholder maps (agent/client/scenario/methodology + bounded history) and `build_chat_context/0` for grounded chat (≤20 clients, 10 visits, 5 calls). Must run with `TenantRepo` pinned.
- **VisitPipeline** (`services/visit_pipeline.ex`) — `process_pre_call`/`process_post_call` (status transitions), `extract_domain_from_email`, chains `Lessons.distill`.
- **Lessons** (`services/lessons.ex`) — LESSONS_DISTILL domain; updates `client.lessons_learned`.
- **Placeholders** (`services/placeholders.ex`) — **prompt-injection mitigations**: regex substitution (no format-string eval), untrusted fields fenced in `<FIELD> … </ FIELD>` tags (space-defanged close), values capped at 20k chars, backtick spans preserved for dial-time passthrough, placeholder regex excludes dots/brackets. The Assembler system prompt instructs the model to treat tagged blocks as inert data and to return JSON only.

---

## 9. Central config distribution
Canonical config lives in the control-plane (`CentralConfig`, `Florina.Repo`). On provision, `seed_tenant/1` copies canonical rows into the tenant **preserving ids**, skipping rows the tenant marked `is_overridden: true`, forcing seeded `is_overridden=false` (`insert_all on_conflict: :replace_all, conflict_target: :id`). `publish_to/1` upserts canonical → one tenant by id, excluding `:id`/`:is_overridden` from replace; `publish_all/0` iterates active tenants with per-tenant failure isolation. Per-tenant context edits set `is_overridden: true` so publishes don't clobber customisations. Effective value = tenant override ?? central default.

---

## 10. Security model & invariants (attack these)
1. **Tenant data isolation** — a request/job for tenant A can never read/write tenant B's data (separate DBs + process-local pinning + fail-closed resolution + `active` gate).
2. **Agent sign-in gate** — only a provider-verified email whose domain is in the tenant's allow-list can create/Use an agent account; OAuth `state` is signed and bound to tenant+provider; sessions renew on login.
3. **Webhook authenticity** — only HMAC-valid, fresh ElevenLabs webhooks are processed.
4. **Secrets at rest** — OAuth tokens and LLM audit payloads are AES-GCM encrypted; passwords are bcrypt.
5. **Prompt injection containment** — untrusted CRM/calendar/transcript text cannot escape its data fence to become model instructions.
6. **Config override safety** — publishing central config never overwrites a tenant's `is_overridden` customisations.
7. **Operator/agent separation** — `/admin/*` requires an operator admin session; agent pages require an agent session; the two are distinct.

---

## 11. Encryption at rest
`Florina.Vault` (`use Cloak.Vault`), single cipher AES-256-GCM (12-byte IV, tag `AES.GCM.V1`). Key: **dev/test use a fixed key hardcoded in `config/{dev,test}.exs` (identical)**; **prod requires `FIELD_ENCRYPTION_KEY`** (runtime.exs raises if missing). Custom Ecto types `Florina.Encrypted.Binary` (bytea) and `Florina.Encrypted.Map` (JSON→encrypted bytea). Vault starts in the supervision tree before any encrypted read.

---

## 12. Config, supervision & deploy
**Supervision order** (`application.ex`, one_for_one): Telemetry → **Vault** → **Repo** → **ConnectionManager** → DNSCluster → PubSub → **Oban** → **Endpoint**; then `Admins.ensure_seed_from_env()` runs post-start (rescues all errors).

**Required at prod boot (raise if missing):** `FIELD_ENCRYPTION_KEY`, `DATABASE_URL`, `SECRET_KEY_BASE`, `DASHBOARD_PASS`. **Optional (feature silently degrades if absent):** all integration keys (`ANTHROPIC_API_KEY`, `ELEVENLABS_*`, `GOOGLE_*`, `MICROSOFT_*`, `PIPEDRIVE_*`), `OAUTH_REDIRECT_BASE`, `PHX_HOST`/`TENANT_BASE_HOST`, `POOL_SIZE`, `ECTO_IPV6`, `DNS_CLUSTER_QUERY`, `DASHBOARD_USER`, `ADMIN_EMAIL`/`ADMIN_PASSWORD`. `ELEVENLABS_WEBHOOK_SECRET` is read in all envs.

**Release ops** (`Florina.Release`): `migrate/0` (control-plane), `migrate_tenants/0` (all tenant DBs), `provision_tenant/3`, `create_admin/2`. **`railway.json` `preDeployCommand` runs `bin/migrate` (control-plane only)** — **per-tenant migrations must be run manually** (`bin/florina rpc 'Florina.Release.migrate_tenants()'`) after a deploy that changes tenant schema. Docker runs as `nobody`; `bin/server` sets `PHX_SERVER`.

---

## 13. Areas flagged for scrutiny (hypotheses — confirm/refute against code)

An internal pass surfaced these. They are **leads, not verdicts** — verify each. Roughly prioritized.

**Auth / access control**
- `GET /t/:slug/whoami` runs `[:browser, :resolve_tenant]` with **no auth** and returns tenant marker labels — confirm it's harmless/diagnostic and consider removing in prod.
- `ChatLive` (global `/chat`) is gated by Basic-Auth on the **HTTP request only**; the LiveView has **no `on_mount`** — assess whether the websocket can be reached without re-auth given a session.
- Session cookie is **signed but not encrypted** — confirm nothing sensitive beyond `admin_id`/`agent_id`/`tenant_slug` is stored.
- Microsoft `fetch_identity` sets `email_verified = is_binary(email)` (any non-nil email "verified"); the `organizations` tenant default mitigates this for work accounts — confirm the gate is sound for all Microsoft account shapes.

**Background jobs / correctness**
- **`PostCallCompletion` appears to have no enqueue site** — verify whether the post-call pipeline (lessons distillation, visit→COMPLETE) actually runs in production. The webhook updates the CallAttempt + broadcasts but may not trigger it.
- Double-dial window: `ScanTenantCalls` checks the dial cap then enqueues `DialCall` with **no Oban `unique` constraint**; concurrent scans could enqueue duplicates (the `DialCall` idempotency guard is the only backstop). Note the guard ignores `FAILED`, so failed attempts count toward the 2/phase cap.
- `CalendarSync` uses a fixed **00:00–23:59 UTC** "today" window — events for tenants far from UTC may be missed.
- `Lessons.distill` may record `GenerationRun.success = true` even when the subsequent `Clients.update` fails — audit vs reality mismatch.
- ElevenLabs→status mapping is duplicated (`Calls.apply_elevenlabs_webhook` vs `SyncPendingCalls`) and not identical.

**Reliability / external calls**
- **Anthropic `Req.post` calls set no `receive_timeout`** — a hung response could block a LiveView task or Oban worker indefinitely.
- Pipedrive API token is sent as a **URL query param** (`api_token=…`) — leaks into logs; `list_organizations` pagination is **unbounded**.
- Microsoft Graph calendar fetch caps at `$top=250` with **no pagination** — silent truncation for heavy calendars.
- ClientSync derives client domain from Pipedrive `cc_email` (`…@pipedrivemail.com`) — may not match the real company domain that calendar matching relies on.
- `max_context_tokens_warn` is stored/published but **never enforced** anywhere — dead config.

**Data model**
- `oauth_credentials` unique index `(provider, purpose, user_id)` with **nullable `user_id`**: Postgres treats NULLs as distinct, so future `florina_mailbox` rows (user_id NULL) aren't uniqueness-constrained (acknowledged; needs a partial index).
- `oauth_credentials.client_id` is **plaintext** while `client_secret` is encrypted.
- `voice_callattempt` has DB columns not mapped in the Ecto schema (`scheduled_time`, `executed_at`, `retry_count`, `scheduled_offset_minutes`).
- Wide cascades: deleting a `voice_user` or `voice_client` cascades to visits → call attempts → generation runs (incl. encrypted audit). `voice_megaprompt` is `ON DELETE RESTRICT` (the only one) — inconsistent.
- `seed_tenant` scenario seeding (`on_conflict: :id`) can collide on `voice_scenario_name_index` if a tenant already has a same-named scenario with a different id (reachable on re-provision/Retry of a dirty tenant, not fresh provisioning).
- `voice_client.status` enum stores Romanian strings (`nou`/`existent`).

**Config / ops / supervision**
- **Secrets handling:** the git repo is clean (`.env` is git-ignored and never committed — verified), but a local `.env` holds real keys; ensure it is never bundled when sharing the code. dev/test share one hardcoded Cloak key.
- CI does **not** run the test suite (local-only) and compiles under `MIX_ENV=dev` — regressions can merge unverified.
- Per-tenant migrations are **not** in `preDeployCommand` — easy to forget after a tenant-schema deploy.
- `postgrex` is unpinned (`>= 0.0.0`).
- `OAuth.upsert_calendar_credential` is a non-atomic read-then-write; concurrent callbacks for the same user could race the unique constraint.
- Tenant connection pools are not individually supervised; a pool crash is detected only on next use.

**Known test-suite note (local only):** per-tenant tests use real (non-sandbox) connections; `Florina.TenantCase` resets each tenant per test. (This was recently hardened; mentioned only because reviewers running tests locally should know tenant DBs are shared across the suite.)

---

## 14. File map (where to look)
- Tenancy: `lib/florina/repo.ex`, `lib/florina/tenant_repo.ex`, `lib/florina/tenants/` (`connection_manager.ex`, `tenant.ex`, `provisioner.ex`, `migrator.ex`, `database_provisioner*.ex`, `connection_opts.ex`, `marker.ex`), `lib/florina/tenants.ex`.
- Web/auth: `lib/florina_web/router.ex`, `lib/florina_web/plugs/`, `lib/florina_web/agent_auth.ex`, `lib/florina_web/admin_auth.ex`, `lib/florina_web/tenant_hook.ex`, `lib/florina_web/controllers/` (auth, admin/session, webhook/eleven_labs, whoami, health), `lib/florina_web/live/`.
- Jobs: `lib/florina/workers/`. Config: `config/*.exs`. App: `lib/florina/application.ex`, `lib/florina/release.ex`.
- Integrations/services: `lib/florina/integrations/`, `lib/florina/services/`, `lib/florina/anthropic*`, `lib/florina/central_config.ex`, `lib/florina/oauth*`.
- Schemas: under each context dir in `lib/florina/`. Migrations: `priv/repo/migrations/` (control-plane), `priv/tenant_repo/migrations/` (per-tenant).
- Encryption: `lib/florina/vault.ex`, `lib/florina/encrypted/`.
- Deploy: `Dockerfile`, `railway.json`, `rel/overlays/bin/`, `mix.exs`, `.github/workflows/ci.yml`.

---

## 15. Suggested review priorities
1. **Tenant isolation** end-to-end (resolution, pinning, Oban pinning, any place `Florina.Repo` vs `TenantRepo` could be confused).
2. **Agent sign-in + OAuth** (state binding, the email gate, token storage, session lifecycle).
3. **Webhook authenticity + the call pipeline** (HMAC window, idempotency/dedup, the `PostCallCompletion` gap, status machines).
4. **Prompt-injection containment** in `Placeholders`/`Assembler`/`DataContext` against hostile CRM/calendar/transcript content.
5. **Secrets & encryption** (key handling, what's encrypted vs plaintext, what's required at boot).
6. **External-call resilience** (timeouts, pagination, error swallowing).
