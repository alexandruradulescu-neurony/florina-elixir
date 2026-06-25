# Backend Port (Django `voice` app → Elixir/Phoenix) — Blueprint

> Autonomous port of the Django backend into the Elixir rebuild. Django source is
> reference-only, extracted to `/tmp/florina-django-ref` (from git `57fb755~1`).
> All business data is **per-customer** → it lives in the **tenant** databases
> (`Florina.TenantRepo`, migrations under `priv/tenant_repo/migrations`).

**Goal:** Recreate the Django backend (data model → contexts → services → background jobs)
natively in Elixir, owning its own data. No Django at runtime.

**Tech:** Ecto schemas on `Florina.TenantRepo`, Ecto.Enum for choices, Oban for jobs.

---

## Reference map (Django → Elixir)

Django table names (kept for fidelity; `voice_callattempt` already exists in the tenant DB).

| Django model | Table | Elixir schema |
|---|---|---|
| User (sales agent) | `voice_user` | `Florina.Accounts.User` |
| Client | `voice_client` | `Florina.Clients.Client` |
| Methodology | `voice_methodology` | `Florina.Methodologies.Methodology` |
| Scenario | `voice_scenario` | `Florina.Scenarios.Scenario` |
| Visit (central) | `voice_visit` | `Florina.Visits.Visit` |
| CallAttempt (DONE) | `voice_callattempt` | `Florina.Calls.CallAttempt` |
| VoicePrompt | `voice_voiceprompt` | `Florina.Calls.VoicePrompt` |
| MegaPrompt | `voice_megaprompt` | `Florina.Prompts.MegaPrompt` |
| GenerationRun | `voice_generationrun` | `Florina.Prompts.GenerationRun` |
| GlobalSettings (singleton) | `voice_globalsettings` | `Florina.Settings.GlobalSettings` |
| ActivityLog | `voice_activitylog` | `Florina.Audit.ActivityLog` |
| GoogleCalendarWatch | `voice_googlecalendarwatch` | `Florina.Calendar.GoogleCalendarWatch` |
| GoogleOauthCredential | `voice_googleoauthcredential` | `Florina.Calendar.GoogleOauthCredential` |

### Enums (Ecto.Enum) — from `voice/constants.py` + model inner classes
- `CallStatus`: SCHEDULED, INITIATED, IN_PROGRESS, COMPLETED, NO_ANSWER, FAILED
- `CallPhase`: PRE, POST  (stored values "PRE"/"POST")
- `VisitStatus`: PLANNED, PRE_CALL_DONE, IN_PROGRESS, POST_CALL_DONE, COMPLETE
- `ClientStatus`: "nou", "existent"  (Romanian stored values — keep exactly)
- `LogLevel`: DEBUG, INFO, WARNING, ERROR, CRITICAL
- `MegaPrompt.Domain`: PRE_CALL, POST_CALL, LESSONS_DISTILL
- `GenerationRun.TriggeredBy`: MANUAL, SCHEDULED, END_OF_MEETING

### Domain constants (module attrs) — `voice/constants.py`
PRE_MEETING_OFFSETS [-60,-30]; POST_MEETING_OFFSETS [15,30]; SCHEDULER_WINDOW 10;
MAX_CALL_ATTEMPTS_PER_PHASE 2; RETRY_DELAY_SECONDS 60.

---

## Gotchas (must handle)
1. **Circular FK:** `voice_user.default_methodology_id` → methodology, and
   `voice_methodology.created_by_id` → user. Create `voice_user` first (without the
   methodology FK), create `voice_methodology` (with created_by FK), then `alter`
   `voice_user` to add `default_methodology_id` references. Same pattern for any cycle.
2. **`voice_callattempt` already exists** (tenant migration created it). Do NOT recreate.
   Optionally add the `visit_id` → `voice_visit` FK constraint once `voice_visit` exists.
3. **Encryption deferred:** Django encrypts (Fernet) `GoogleOauthCredential.{token,
   refresh_token,client_secret}` and `GenerationRun.{context_bundle,claude_request,
   claude_response,parsed_outputs,error}`. For now store as plain `:text`/`:map`; add
   encryption-at-rest (Cloak) as a later task. Note it in the schemas.
4. **File fields:** `Methodology.source_material` (FileField) → store a `:string` path/URL
   column; real upload handling is a later concern.
5. **User vs auth:** port `voice_user` as the *agent* data entity (username, email,
   pipedrive_user_id, phone_number, is_sales_agent, default_methodology_id, name fields).
   Login/auth is a separate slice — do NOT pull in Django auth machinery.
6. **Singleton GlobalSettings:** one row per tenant DB; provide a `load/0` that
   get-or-creates the single row.

---

## Phases (execute in order; commit each; tests local-only & git-ignored)

- **Phase 1 — Data model.** Ecto.Enum modules + ONE tenant migration creating all the
  tables above (+ the `voice_callattempt.visit_id` FK) + all 12 new schemas with
  changesets. Compile clean; basic schema/changeset tests; full suite green.
- **Phase 2 — Contexts (CRUD + queries).** One context per domain
  (Accounts, Clients, Methodologies, Scenarios, Visits, Calls/VoicePrompt, Prompts/Mega+
  GenerationRun, Settings, Audit, Calendar). Port the key reads from `voice/selectors.py`
  and the writes from `voice/views.py`/forms. All via `TenantRepo`.
- **Phase 3 — Services (business logic).** `assembler` (prompt assembly), `data_context`,
  `prompt_context`, `placeholders`, `lessons`, `visit_pipeline`. Pure logic first; LLM
  calls reuse `Florina.Anthropic`.
- **Phase 4 — Background jobs.** Port `voice/tasks.py` (scheduler, pre/post call dialing,
  sync) to Oban workers + Oban Cron.
- **Phase 5 — External integrations.** `services/elevenlabs`, `calendar/google`,
  `crm/pipedrive`, `services/llm` — API clients via `Req`.

Each phase: schemas/modules in `lib/florina/<domain>/`, tenant migrations in
`priv/tenant_repo/migrations`, contexts use `Florina.TenantRepo`.
