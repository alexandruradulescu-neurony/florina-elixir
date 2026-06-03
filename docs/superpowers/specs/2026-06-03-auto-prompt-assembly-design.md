# Auto Prompt Assembler — Design

Date: 2026-06-03
Status: Approved (brainstorm complete; ready for implementation plan)

## 1. Problem and goal

The current `voice/services/prompt_builder.py` assembles a thin context block (client + methodology + visit + manager notes) and asks Claude to produce one voice-prompt per pre/post call. The result is generic compared to the bar set by the hand-crafted prompts in `prompts_export/` (e.g. `Domus_Imobiliare_..._pre_call_prompt.txt`): client-specific facts, 5 verification questions with correct/unknown/wrong branches, suggested meeting questions, scenario-aware closing.

**Goal.** Build an "Auto Prompt Assembler" that, for every Visit, automatically produces ElevenLabs voice prompts that approach the quality of the hand-crafted Domus example — by pulling all relevant context the app already holds, feeding it through a small set of versioned, manager-editable mega-prompts, and closing the loop with per-client lessons learned distilled from prior calls.

The mega-prompts are treated as the heart of the product. Persistence, versioning, and guarding are first-class requirements, not afterthoughts.

## 2. Scope

In scope:

- New `MegaPrompt` model with three domains: `PRE_CALL`, `POST_CALL`, `LESSONS_DISTILL`. Versioned, single-active-per-domain, staff-only edit.
- New `Scenario` entity (own model — minimal now, can grow attributes later).
- New `GenerationRun` model for full audit trail of every assembly attempt.
- New `Client.lessons_learned` field — populated by the closed-loop distiller, manually editable by manager.
- Per-field locks on `Visit` so manager edits survive regeneration.
- New triggers: manual button per domain, scheduled T-N hours before visit (pre-call), end-of-meeting hook (post-call → lessons distill chain).
- Seed-file / management-command bookkeeping so mega-prompts are recoverable from `git` even if the DB is wiped.
- Replace the two `GlobalSettings` meta-prompt text fields and the existing `prompt_builder.py` logic.

Out of scope (deliberately, for v1):

- Passing methodology PDFs directly to Claude — keep using `Methodology.ai_summary`.
- Raw call transcripts in context — use `Visit.post_call_summary` (already AI-distilled).
- External lookups (listafirme, web, LinkedIn) at assembly time. Manager can paste relevant facts into `manager_notes` or `Client.ai_summary`.
- Diff view between regenerations.
- Dry-run / preview when editing a mega-prompt. Rollback via versioning is the safety net.
- Two-step "outline → finish" pipeline. One Claude call per domain is the v1 architecture.

## 3. High-level architecture

Per assembly:

1. **Collect** the context bundle for the visit (section 5).
2. **Render** the active mega-prompt for the domain (`PRE_CALL` or `POST_CALL`), interpolating placeholders.
3. **Call Claude once** for that domain. Claude returns a JSON object `{body, first_message}`.
4. **Parse** and **write** only the unlocked fields. Skip the Claude call entirely if both fields in the domain are locked.
5. **Log** a `GenerationRun` row (request, response, parsed outputs, tokens, success, error, who triggered).

`PRE_CALL` and `POST_CALL` run independently and at different moments. `LESSONS_DISTILL` is not user-facing — it chains automatically off the post-call success path, updating the client's `lessons_learned` for use in future pre-call runs.

## 4. Data model

### 4.1 `MegaPrompt` (new)

| Field | Type | Notes |
|---|---|---|
| `domain` | CharField (choices: `PRE_CALL`, `POST_CALL`, `LESSONS_DISTILL`), indexed | One active per domain |
| `name` | CharField(max_length=255) | Human label for the version |
| `meta_prompt` | TextField | The instructions sent to Claude. Supports placeholders (see 4.6) |
| `is_active` | BooleanField, indexed, default False | Enforced one-per-domain by app logic in toggle view |
| `version` | PositiveIntegerField, default 1 | Auto-incremented per domain on save |
| `created_by` | FK User, nullable | Who created this version |
| `created_at` / `updated_at` | DateTime | Standard |

Constraints / behaviors:

- Save creates a new row, never mutates an existing row in place (UI builds this guarantee).
- Activating a version atomically (`select_for_update`) deactivates any other active version in the same domain.
- Deletion of a non-active version requires explicit confirmation. Active version cannot be deleted.
- Ordering: `("domain", "-version")`.

### 4.2 `Scenario` (new)

| Field | Type | Notes |
|---|---|---|
| `name` | CharField(max_length=120), unique | e.g. "Discovery", "Follow-up", "Closing", "Debrief" |
| `slug` | SlugField, unique | Stable identifier for templates and code |
| `description` | TextField, blank | Optional notes for managers |
| `is_active` | BooleanField, default True | Hide retired scenarios without deleting |
| `created_at` / `updated_at` | DateTime | Standard |

Seeded with a starter set: `discovery`, `follow-up`, `closing`, `debrief`, `other`. The model exists now precisely so it can grow attributes (default question set, typical duration, recommended methodology, etc.) without a refactor.

### 4.3 `Visit` (additions to existing model)

| Field | Type | Notes |
|---|---|---|
| `scenario` | FK Scenario, nullable, SET_NULL | Drives mega-prompt's question-shaping logic |
| `pre_call_prompt_locked` | BooleanField, default False | True = manager edited; regen skips |
| `pre_call_first_message_locked` | BooleanField, default False | Same |
| `post_call_prompt_locked` | BooleanField, default False | Same |
| `post_call_first_message_locked` | BooleanField, default False | Same |

Note: the existing fields `pre_call_prompt`, `pre_call_first_message`, `post_call_prompt`, `post_call_first_message` are unchanged. `goal` stays inside `manager_notes` — no structured field for it.

A pre-save signal (or form-level logic on the manual edit views) sets the corresponding `*_locked` flag to True when the field changes via manager edit (not when changed by the assembler).

### 4.4 `Client` (addition)

| Field | Type | Notes |
|---|---|---|
| `lessons_learned` | TextField, blank | Distilled by `LESSONS_DISTILL`; editable by manager |

The distiller always rewrites the full block. Manual edits are preserved on the next distill by being shown to Claude with an explicit "respect any manual edits" instruction.

### 4.5 `GenerationRun` (new)

| Field | Type | Notes |
|---|---|---|
| `visit` | FK Visit, nullable, indexed | Set for `PRE_CALL` / `POST_CALL` runs; NULL for `LESSONS_DISTILL` |
| `client` | FK Client, nullable, indexed | Set for `LESSONS_DISTILL` runs; NULL for `PRE_CALL` / `POST_CALL` (the client can be reached via `visit.client`) |
| `domain` | CharField (same choices as MegaPrompt) | Which mega-prompt was invoked |
| `mega_prompt` | FK MegaPrompt, on_delete=PROTECT | The exact version used |
| `triggered_by` | CharField (`MANUAL`, `SCHEDULED`, `END_OF_MEETING`) | How this run started |
| `context_bundle` | JSONField | The structured context fed in (for debugging) |
| `claude_request` | TextField | Fully rendered meta-prompt sent to Claude |
| `claude_response` | TextField | Raw response |
| `parsed_outputs` | JSONField, default dict | The post-parse fields |
| `input_tokens` | PositiveIntegerField, default 0 | From Claude usage block |
| `output_tokens` | PositiveIntegerField, default 0 | From Claude usage block |
| `success` | BooleanField, default False | False if call failed or JSON parse failed |
| `error` | TextField, blank | Stack trace / message on failure |
| `created_by` | FK User, nullable | Set when triggered manually |
| `created_at` | DateTimeField, auto_now_add | |

Retention: forever for v1. Re-evaluate when row volume forces it.

### 4.6 Placeholders supported in `meta_prompt`

| Placeholder | Filled with |
|---|---|
| `{agent_first_name}` | `visit.agent.first_name` |
| `{client_name}` | `visit.client.name` |
| `{visit_time}` | `visit.start_time` formatted in Romanian locale |
| `{scenario}` | `visit.scenario.name` or "" |
| `{methodology_summary}` | `visit.get_effective_methodology().ai_summary` or "" |
| `{client_industry}` | `visit.client.industry` or "" |
| `{client_summary}` | `visit.client.ai_summary` or "" |
| `{client_lessons_learned}` | `visit.client.lessons_learned` or "" |
| `{manager_notes}` | `visit.manager_notes` or "" |
| `{interaction_history}` | Last 5 entries from `visit.client.interaction_history`, formatted as bullets |
| `{deal_history}` | Last 3 entries from `visit.client.deal_history`, formatted as bullets |
| `{client_past_visits}` | Last 3 visits for this client: title, date, post_call_summary, outcome |
| `{agent_recent_visits}` | Last 5 visits by this agent: title, date, post_call_summary, outcome |
| `{visit_transcript}` (POST only) | Full transcript of the meeting just completed |
| `{pre_call_brief}` (POST only) | `visit.pre_call_prompt` (the brief the agent was coached on) |
| `{current_lessons_learned}` (DISTILL only) | `client.lessons_learned` |
| `{new_post_call_summary}` (DISTILL only) | The summary that triggered the distill |
| `{evaluation_outcome}` (DISTILL only) | The evaluation outcome string |

Unknown placeholders left untouched — the assembler logs a warning but does not fail the call.

## 5. Context bundle (what goes to Claude)

**PRE_CALL bundle** — fields used to fill placeholders 4.6:

- Visit identity: title, start_time, attendees, scenario, manager_notes
- Client: name, industry, ai_summary, lessons_learned, interaction_history (last 5), deal_history (last 3)
- Methodology: name, ai_summary
- History: client's last 3 visits (title + date + post_call_summary + evaluation outcome), agent's last 5 visits (same fields, lighter signal)

**POST_CALL bundle** — same as PRE_CALL plus:

- The transcript of the meeting just completed
- The pre-call brief that was used (`visit.pre_call_prompt`)

**LESSONS_DISTILL bundle** — for closed loop:

- `client.lessons_learned` (current — to update, not append)
- The new post-call summary that just completed
- The evaluation outcome
- A short manifest of which entries were manually edited (so the distiller respects them)

## 6. Triggers

| Trigger | Domain | Notes |
|---|---|---|
| "Regenerate pre-call" button on Visit page | PRE_CALL | Manual; sets `created_by` on the run |
| "Regenerate post-call" button on Visit page | POST_CALL | Manual |
| Scheduled job at T-N hours before visit | PRE_CALL | N from `GlobalSettings.pre_call_offset_minutes` (re-used). Idempotent: if both pre fields are locked, the job logs "skipped (locked)" without calling Claude |
| End-of-meeting webhook | POST_CALL, then LESSONS_DISTILL | Post-call regen runs first; if it succeeds and a post_call_summary is produced, lessons distillation runs as a follow-up step |

Scheduled jobs hook into the existing scheduler app (`voice/services/scheduler.py`).

## 7. Persistence, guarding, recovery (prompts are the product)

Layered defense against loss of prompt data:

1. **DB versioning.** Edits create new rows; old versions are kept forever; rollback = activate older row. Atomic single-active-per-domain enforced via `select_for_update` in the toggle view.
2. **Seed files in `git`.** `voice/management/commands/seed_data/mega_prompts/{pre_call,post_call,lessons_distill}.txt`. On every save of an active version, the seed file for that domain is auto-rewritten so the repo always carries the latest active text. The intent is for these files to be committed alongside ordinary code changes — they are the human-readable source of truth.
3. **Management commands** (recruitflow pattern):
   - `seed_mega_prompts [--force]` — idempotent bootstrap from seed files. Used on fresh deploy. `--force` overrides existing active versions.
   - `export_mega_prompts` — re-emit seed files from current active versions (manual safety net if auto-export ever skipped).
4. **Backup via existing `dumpdata` flow.** Extend the existing backup script to include `voice.MegaPrompt`, `voice.Client` (for `lessons_learned`), `voice.Scenario`, and recent `voice.GenerationRun`.
5. **Access control.** All mega-prompt edit/activate/delete views require `is_staff` (using a `_StaffRequiredMixin` similar to recruitflow).
6. **ActivityLog entry** on every meaningful change: create version, activate, deactivate, delete. Captures user, timestamp, domain, version.
7. **App-layer guard** against deleting the currently active version of any domain.

Net effect: losing a mega-prompt would require simultaneous loss of DB, seed files, and dumpdata backups.

## 8. Locking semantics

- All four `*_locked` flags default `False`.
- Manager edit via the Visit form sets the corresponding flag to `True` (so a manual tweak isn't blown away by the next regen).
- Lock icon on the Visit page toggles the flag explicitly. Manager unlocks to allow regeneration.
- Assembler always reads current lock state immediately before writing — never writes a locked field.
- If both fields in a domain are locked, the assembler skips the Claude call entirely and logs `success=True, parsed_outputs={}, skipped=True` in `GenerationRun.context_bundle["skipped_reason"]`.

## 9. Token guardrail

- `GenerationRun.input_tokens` and `output_tokens` populated from Claude's `usage` block.
- New `GlobalSettings.max_context_tokens_warn` (default 50_000).
- When a run's input exceeds the threshold, the assembler logs a WARNING and marks the run with a `large_context=True` entry in `context_bundle`. The Visit page renders a small badge so the manager knows to consider trimming history.
- Anthropic prompt caching is enabled for static parts (the rendered mega-prompt's invariant prefix) — same Claude model across calls.

## 10. UI surfaces

### 10.1 Mega-prompts admin (`/voice/mega-prompts/`)

- List view grouped by domain (PRE_CALL, POST_CALL, LESSONS_DISTILL). Within each, versions desc; active row highlighted.
- "New version" button per domain — opens the edit form.
- Edit form: name + meta_prompt textarea + save (always creates new version).
- Per-row actions: "Activate" (atomic swap), "Delete" (disallowed for active row), "Copy to new version".
- Staff-only access (`is_staff` test).

### 10.2 Visit page additions

- Per-field lock icons (4 fields). Click to toggle. Tooltip explains semantics.
- Two action buttons: "Regenerate pre-call" and "Regenerate post-call". Each shows a spinner and reloads when done; on failure shows the error from the `GenerationRun`.
- A small "Last run" panel: domain, timestamp, version used, success/failure, link to the `GenerationRun` detail.

### 10.3 Client page addition

- `lessons_learned` editor (multi-line text). Save triggers an ActivityLog entry.
- A small "History" link showing recent `GenerationRun` rows with `domain=LESSONS_DISTILL` for this client.

### 10.4 GenerationRun list (`/voice/generation-runs/`)

- Filterable by domain, visit, client, success.
- Detail view shows full request/response, parsed outputs, tokens, error if any.
- Staff-only.

## 11. Service layer

New module `voice/services/assembler.py` replaces the body of `prompt_builder.py` (callers are migrated):

- `assemble_pre_call(visit, triggered_by, user=None) -> GenerationRun`
- `assemble_post_call(visit, triggered_by, user=None) -> GenerationRun`

New module `voice/services/lessons.py`:

- `distill_lessons(client, new_post_call_summary, evaluation_outcome, triggered_by, user=None) -> GenerationRun`

Each function: (1) loads the active `MegaPrompt` for its domain; if none, logs an error and returns a failed `GenerationRun`. (2) builds the context bundle. (3) calls Claude via the existing `voice/services/llm.py`. (4) parses JSON. (5) writes unlocked target fields. (6) writes the `GenerationRun`.

The post-call success path inside the end-of-meeting webhook chains into `distill_lessons` after writing the post-call summary.

## 12. Migration of existing code and data

1. New migration adds `MegaPrompt`, `Scenario`, `GenerationRun`, the four `Visit.*_locked` fields, `Visit.scenario`, `Client.lessons_learned`, `GlobalSettings.max_context_tokens_warn`.
2. A data migration seeds `Scenario` with the starter list (`discovery`, `follow-up`, `closing`, `debrief`, `other`).
3. A second data migration copies the existing `GlobalSettings.pre_call_meta_prompt` and `GlobalSettings.post_call_meta_prompt` into new `MegaPrompt` rows (domain PRE_CALL / POST_CALL, version 1, active=True). If empty, the seed file content from the new `seed_data/mega_prompts/*.txt` is used instead.
4. Once migrated, `GlobalSettings.pre_call_meta_prompt` and `GlobalSettings.post_call_meta_prompt` fields are removed in a subsequent migration. `voice/services/prompt_builder.py` is deleted (its callers now use `assembler.py`).

## 13. Tests

Coverage targets:

- `MegaPrompt`: version auto-increment, atomic single-active toggle, staff-only access, "cannot delete active version".
- `Scenario`: basic CRUD.
- `Visit`: lock flags default False; manual edit flips the relevant flag.
- `Client.lessons_learned`: manual edit logs an ActivityLog entry.
- `assembler.assemble_pre_call`: happy path; both-locked skip path; one-locked partial write; bad JSON returns failed `GenerationRun`; missing active mega-prompt returns failed run; placeholder substitution.
- `assembler.assemble_post_call`: same matrix.
- `lessons.distill_lessons`: happy path; manual-edit preservation via instruction.
- `seed_mega_prompts` command: idempotent; `--force` behavior.
- `export_mega_prompts` command: writes correct file contents.
- Triggers: scheduled job calls `assemble_pre_call` at the right offset; end-of-meeting webhook calls `assemble_post_call` then `distill_lessons`.

## 14. Open questions to revisit after first slice

- Should `Scenario` later carry default question sets / typical duration / recommended methodology? (Out of v1.)
- Should `GenerationRun` get an auto-prune policy past N months? (Forever for v1.)
- Should the mega-prompt UI gain a "diff against previous version" view? (Out of v1; nice-to-have.)

## 15. Files touched (rough)

New:

- `voice/services/assembler.py`
- `voice/services/lessons.py`
- `voice/management/commands/seed_mega_prompts.py`
- `voice/management/commands/export_mega_prompts.py`
- `voice/management/commands/seed_data/mega_prompts/pre_call.txt`
- `voice/management/commands/seed_data/mega_prompts/post_call.txt`
- `voice/management/commands/seed_data/mega_prompts/lessons_distill.txt`
- `voice/templates/voice/mega_prompt_list.html`
- `voice/templates/voice/mega_prompt_form.html`
- `voice/templates/voice/generation_run_list.html`
- `voice/templates/voice/generation_run_detail.html`
- `voice/migrations/00XX_auto_prompt_assembler.py`
- `voice/migrations/00XY_seed_scenarios.py`
- `voice/migrations/00XZ_migrate_global_meta_prompts.py`
- `voice/migrations/00XQ_remove_globalsettings_meta_prompts.py`

Modified:

- `voice/models.py` (new models, Visit/Client/GlobalSettings additions)
- `voice/views.py` (mega-prompt admin, regenerate buttons, lessons_learned editor)
- `voice/urls.py`
- `voice/services/scheduler.py` (PRE_CALL scheduled trigger)
- `voice/webhook_views.py` or wherever end-of-meeting fires (POST_CALL + LESSONS_DISTILL chain)
- `voice/admin.py` (register new models)
- `voice/templatetags/` (lock icon partial if needed)
- `voice/tests.py` or split test files
- `voice/services/llm.py` (token usage extraction if not already returned)

Deleted (after migration):

- `voice/services/prompt_builder.py`
