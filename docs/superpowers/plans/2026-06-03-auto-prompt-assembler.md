# Auto Prompt Assembler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current `voice/services/prompt_builder.py` with a versioned, manager-editable Auto Prompt Assembler that generates the four ElevenLabs voice prompts on a Visit (pre/post call body + first message), driven by two domain-scoped mega-prompts and a closed-loop "lessons learned" distiller.

**Architecture:** Two mega-prompts (`PRE_CALL`, `POST_CALL`) plus a third (`LESSONS_DISTILL`) chained off post-call success. Each is a versioned `MegaPrompt` row (single-active-per-domain), backed by seed files in git. Per-field locks on `Visit` so manager edits survive regeneration. Every assembly writes a `GenerationRun` audit row. Closed loop populates `Client.lessons_learned`, which feeds the next pre-call assembly.

**Tech Stack:** Django 4.2 (+ `django-apscheduler` for scheduled jobs), `anthropic` SDK 0.80+, Python 3.12. Server runs on **port 8007** (project rule — see memory).

**Test policy (project-specific):** Test files are NEVER committed to GitHub. Critical service-layer pieces get local-only tests under `voice/_tests_local/` (added to `.gitignore` in Task 0). Everything else is verified via manual smoke (dev server + admin/UI + `manage.py shell`). See [no-committed-tests memory](../../../../../.claude/projects/-Users-alex-Code-proj-salesassistant/memory/feedback_no_committed_tests.md).

**Spec:** [docs/superpowers/specs/2026-06-03-auto-prompt-assembly-design.md](../specs/2026-06-03-auto-prompt-assembly-design.md)

---

## File structure

### New files (committed)
- `voice/services/prompt_context.py` — assembles the context bundle from Visit + related data
- `voice/services/assembler.py` — orchestrates one assembly (pre or post): load template → render → call Claude → parse → write unlocked fields → log GenerationRun
- `voice/services/lessons.py` — runs `LESSONS_DISTILL` to update `Client.lessons_learned`
- `voice/management/commands/seed_mega_prompts.py`
- `voice/management/commands/export_mega_prompts.py`
- `voice/management/commands/seed_data/mega_prompts/pre_call.txt`
- `voice/management/commands/seed_data/mega_prompts/post_call.txt`
- `voice/management/commands/seed_data/mega_prompts/lessons_distill.txt`
- `voice/templates/voice/mega_prompt_list.html`
- `voice/templates/voice/mega_prompt_form.html`
- `voice/templates/voice/generation_run_list.html`
- `voice/templates/voice/generation_run_detail.html`
- Migration files (auto-generated; numbers `0017+`)

### New files (local-only, gitignored)
- `voice/_tests_local/` — Django TestCase suites for assembler, lessons distiller, lock semantics, seed/export commands

### Modified files
- `voice/models.py` — new models + Visit/Client/GlobalSettings additions
- `voice/admin.py` — register new models
- `voice/views.py` — mega-prompt CRUD, regenerate buttons, lock toggles, lessons editor, generation-run views
- `voice/urls.py` — new routes
- `voice/forms.py` — MegaPromptForm; flips per-field locks on visit edit
- `voice/tasks.py` — call assembler instead of prompt_builder
- `voice/webhook_views.py` — post-call success path chains `assemble_post_call` then `distill_lessons`
- `voice/services/llm.py` — return token usage alongside text
- `voice/services/__init__.py` — drop old exports; add new
- `voice/templates/voice/visit_detail.html` (or whatever the visit page is) — lock icons, regenerate buttons, last-run panel
- `voice/templates/voice/client_detail.html` (or equivalent) — lessons_learned editor
- `.gitignore` — add `voice/_tests_local/`

### Deleted (last task)
- `voice/services/prompt_builder.py`

---

## Tasks

### Task 0: Bootstrap local-test directory + .gitignore

**Files:**
- Create: `voice/_tests_local/__init__.py` (empty)
- Modify: `.gitignore`

- [ ] **Step 1: Add the dir and stub package**

```bash
mkdir -p voice/_tests_local
touch voice/_tests_local/__init__.py
```

- [ ] **Step 2: Append to `.gitignore`**

Open `.gitignore` and add at the bottom:

```
# Local-only tests — never commit
voice/_tests_local/
```

- [ ] **Step 3: Verify the dir is ignored**

Run: `git status --short`
Expected: `.gitignore` shows as modified; `voice/_tests_local/` does NOT appear in the output.

- [ ] **Step 4: Commit the .gitignore change**

```bash
git add .gitignore
git commit -m "Ignore voice/_tests_local/ (local-only test dir)"
```

---

### Task 1: Add MegaPrompt model

**Files:**
- Modify: `voice/models.py` (append after `GlobalSettings` block)
- Create migration: auto-generated `voice/migrations/0017_megaprompt.py`

- [ ] **Step 1: Append `MegaPrompt` to `voice/models.py`**

Add at the end of the file:

```python
class MegaPrompt(models.Model):
    """Versioned, single-active-per-domain meta-prompt used by the Auto Prompt Assembler.

    Edit always creates a new version (never in-place). Activating a version
    atomically deactivates any other active version in the same domain.
    Old versions are retained forever; rollback = activating an older row.
    """

    class Domain(models.TextChoices):
        PRE_CALL = "PRE_CALL", _("Pre-call")
        POST_CALL = "POST_CALL", _("Post-call")
        LESSONS_DISTILL = "LESSONS_DISTILL", _("Lessons distill")

    domain = models.CharField(
        max_length=20,
        choices=Domain.choices,
        db_index=True,
        help_text="Which assembler domain this template drives",
    )
    name = models.CharField(max_length=255, help_text="Human label for this version")
    meta_prompt = models.TextField(
        help_text="Instructions sent to Claude. Supports {placeholders} — see spec §4.6."
    )
    is_active = models.BooleanField(
        default=False,
        db_index=True,
        help_text="Only one active version per domain at a time",
    )
    version = models.PositiveIntegerField(default=1)
    created_by = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="created_mega_prompts",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Mega Prompt")
        verbose_name_plural = _("Mega Prompts")
        ordering = ["domain", "-version"]
        constraints = [
            models.UniqueConstraint(
                fields=["domain", "version"],
                name="megaprompt_unique_domain_version",
            ),
        ]

    def __str__(self) -> str:
        marker = " ✓" if self.is_active else ""
        return f"[{self.get_domain_display()}] {self.name} v{self.version}{marker}"
```

- [ ] **Step 2: Generate the migration**

Run: `python manage.py makemigrations voice`
Expected: a file named like `voice/migrations/0017_megaprompt.py` is created.

- [ ] **Step 3: Apply the migration**

Run: `python manage.py migrate`
Expected: `Applying voice.0017_megaprompt... OK`

- [ ] **Step 4: Smoke verify via shell**

Run: `python manage.py shell -c "from voice.models import MegaPrompt; print(MegaPrompt.Domain.choices); print(MegaPrompt.objects.count())"`
Expected: prints the 3 choices and `0`.

- [ ] **Step 5: Commit**

```bash
git add voice/models.py voice/migrations/0017_megaprompt.py
git commit -m "Add MegaPrompt model (versioned, single-active-per-domain)"
```

---

### Task 2: Add Scenario model + data migration seeding starter set

**Files:**
- Modify: `voice/models.py` (append `Scenario`)
- Migrations: one auto-generated for the model, one empty data migration

- [ ] **Step 1: Append `Scenario` to `voice/models.py`**

```python
class Scenario(models.Model):
    """Visit scenario type (discovery / follow-up / closing / debrief / other).

    Own entity so it can grow attributes later (default question set, expected
    duration, etc.) without a refactor.
    """

    name = models.CharField(max_length=120, unique=True)
    slug = models.SlugField(max_length=120, unique=True)
    description = models.TextField(blank=True, default="")
    is_active = models.BooleanField(default=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = _("Scenario")
        verbose_name_plural = _("Scenarios")
        ordering = ["name"]

    def __str__(self) -> str:
        return self.name
```

- [ ] **Step 2: Generate the schema migration**

Run: `python manage.py makemigrations voice`
Expected: `voice/migrations/0018_scenario.py` created.

- [ ] **Step 3: Generate an empty data migration**

Run: `python manage.py makemigrations voice --empty --name seed_scenarios`
Expected: `voice/migrations/0019_seed_scenarios.py` created.

- [ ] **Step 4: Fill in the data migration**

Open `voice/migrations/0019_seed_scenarios.py` and replace `operations = []` with:

```python
def seed_scenarios(apps, schema_editor):
    Scenario = apps.get_model("voice", "Scenario")
    starter = [
        ("Discovery", "discovery", "First substantive conversation; explore needs and fit."),
        ("Follow-up", "follow-up", "Continuing an active deal; advance toward decision."),
        ("Closing", "closing", "Securing a commitment / signature."),
        ("Debrief", "debrief", "Post-meeting reflection / loss analysis."),
        ("Other", "other", "Catch-all when the above don't apply."),
    ]
    for name, slug, desc in starter:
        Scenario.objects.get_or_create(
            slug=slug,
            defaults={"name": name, "description": desc, "is_active": True},
        )


def unseed_scenarios(apps, schema_editor):
    Scenario = apps.get_model("voice", "Scenario")
    Scenario.objects.filter(slug__in=["discovery", "follow-up", "closing", "debrief", "other"]).delete()


operations = [
    migrations.RunPython(seed_scenarios, unseed_scenarios),
]
```

(Keep the existing `dependencies` and `from django.db import migrations` lines that `makemigrations --empty` produced.)

- [ ] **Step 5: Apply migrations**

Run: `python manage.py migrate`
Expected: both `0018_scenario` and `0019_seed_scenarios` apply OK.

- [ ] **Step 6: Smoke verify**

Run: `python manage.py shell -c "from voice.models import Scenario; print(list(Scenario.objects.values_list('slug', flat=True)))"`
Expected: `['closing', 'debrief', 'discovery', 'follow-up', 'other']` (alphabetical by name).

- [ ] **Step 7: Commit**

```bash
git add voice/models.py voice/migrations/0018_scenario.py voice/migrations/0019_seed_scenarios.py
git commit -m "Add Scenario entity + seed starter set"
```

---

### Task 3: Visit additions — scenario FK + four lock flags

**Files:**
- Modify: `voice/models.py` (Visit class — section already at line 390)
- Migration auto-generated

- [ ] **Step 1: Add fields to `Visit`**

In `voice/models.py`, locate the `Visit` model. After the existing `methodology` field block (around line 424) add:

```python
    scenario = models.ForeignKey(
        Scenario,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="visits",
        help_text="Visit scenario type — drives mega-prompt question shaping",
    )
```

After the four prompt fields (`pre_call_prompt`, `pre_call_first_message`, `post_call_prompt`, `post_call_first_message`) — i.e. just after `post_call_first_message` definition around line 444 — add:

```python
    pre_call_prompt_locked = models.BooleanField(
        default=False,
        help_text="True after a manual edit; assembler will skip this field on regen",
    )
    pre_call_first_message_locked = models.BooleanField(default=False)
    post_call_prompt_locked = models.BooleanField(default=False)
    post_call_first_message_locked = models.BooleanField(default=False)
```

- [ ] **Step 2: Generate migration**

Run: `python manage.py makemigrations voice`
Expected: `voice/migrations/0020_visit_scenario_visit_pre_call_prompt_locked_and_more.py` (or similar) created.

- [ ] **Step 3: Apply migration**

Run: `python manage.py migrate`
Expected: applies OK.

- [ ] **Step 4: Smoke verify**

Run: `python manage.py shell -c "from voice.models import Visit; v = Visit.objects.first(); print(v.scenario, v.pre_call_prompt_locked, v.post_call_first_message_locked) if v else print('no visits')"`
Expected: either `no visits` or `None False False` for an existing row.

- [ ] **Step 5: Commit**

```bash
git add voice/models.py voice/migrations/0020_*.py
git commit -m "Add Visit.scenario + four per-field lock flags"
```

---

### Task 4: Client.lessons_learned

**Files:**
- Modify: `voice/models.py` (Client class)
- Migration auto-generated

- [ ] **Step 1: Add the field to `Client`**

In `voice/models.py`, locate the `Client` model. Append a field (near its other text fields like `ai_summary`):

```python
    lessons_learned = models.TextField(
        blank=True,
        default="",
        help_text="Distilled lessons from prior calls; updated by LESSONS_DISTILL after each post-call. Editable.",
    )
```

- [ ] **Step 2: Generate + apply migration**

```bash
python manage.py makemigrations voice
python manage.py migrate
```

Expected: `voice/migrations/0021_client_lessons_learned.py` (or similar) created and applied.

- [ ] **Step 3: Smoke verify**

Run: `python manage.py shell -c "from voice.models import Client; c = Client.objects.first(); print(repr(c.lessons_learned)) if c else print('no clients')"`
Expected: empty string `''` for any existing client.

- [ ] **Step 4: Commit**

```bash
git add voice/models.py voice/migrations/0021_*.py
git commit -m "Add Client.lessons_learned (closed-loop memory)"
```

---

### Task 5: GenerationRun model

**Files:**
- Modify: `voice/models.py` (append)
- Migration auto-generated

- [ ] **Step 1: Append `GenerationRun`**

```python
class GenerationRun(models.Model):
    """Audit log of every Auto Prompt Assembler run (pre, post, lessons distill).

    Visit is set for PRE_CALL/POST_CALL runs; Client is set for LESSONS_DISTILL
    runs. Kept forever for now — re-evaluate when volume forces it.
    """

    class TriggeredBy(models.TextChoices):
        MANUAL = "MANUAL", _("Manual")
        SCHEDULED = "SCHEDULED", _("Scheduled")
        END_OF_MEETING = "END_OF_MEETING", _("End of meeting")

    visit = models.ForeignKey(
        "Visit",
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name="generation_runs",
        help_text="Set for PRE_CALL/POST_CALL; NULL for LESSONS_DISTILL",
    )
    client = models.ForeignKey(
        "Client",
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name="generation_runs",
        help_text="Set for LESSONS_DISTILL; NULL for PRE_CALL/POST_CALL (reach via visit.client)",
    )
    domain = models.CharField(
        max_length=20,
        choices=MegaPrompt.Domain.choices,
        db_index=True,
    )
    mega_prompt = models.ForeignKey(
        MegaPrompt,
        on_delete=models.PROTECT,
        related_name="generation_runs",
        help_text="The exact MegaPrompt version that was used",
    )
    triggered_by = models.CharField(max_length=20, choices=TriggeredBy.choices)
    context_bundle = models.JSONField(default=dict, blank=True)
    claude_request = models.TextField(blank=True, default="")
    claude_response = models.TextField(blank=True, default="")
    parsed_outputs = models.JSONField(default=dict, blank=True)
    input_tokens = models.PositiveIntegerField(default=0)
    output_tokens = models.PositiveIntegerField(default=0)
    success = models.BooleanField(default=False, db_index=True)
    error = models.TextField(blank=True, default="")
    created_by = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="generation_runs",
    )
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        verbose_name = _("Generation Run")
        verbose_name_plural = _("Generation Runs")
        ordering = ["-created_at"]

    def __str__(self) -> str:
        target = self.visit_id or self.client_id or "?"
        return f"GenerationRun #{self.pk} [{self.domain}] target={target} ok={self.success}"
```

- [ ] **Step 2: Generate + apply migration**

```bash
python manage.py makemigrations voice
python manage.py migrate
```

Expected: a `0022_generationrun.py` (or similar) migration appears and applies cleanly.

- [ ] **Step 3: Smoke verify**

Run: `python manage.py shell -c "from voice.models import GenerationRun; print(GenerationRun.objects.count(), [f.name for f in GenerationRun._meta.get_fields()])"`
Expected: `0` and the list of fields.

- [ ] **Step 4: Commit**

```bash
git add voice/models.py voice/migrations/0022_*.py
git commit -m "Add GenerationRun audit model"
```

---

### Task 6: GlobalSettings.max_context_tokens_warn

**Files:**
- Modify: `voice/models.py` (GlobalSettings class around line 484)
- Migration auto-generated

- [ ] **Step 1: Add the field**

In `voice/models.py`, locate `GlobalSettings`. After the existing offset fields add:

```python
    max_context_tokens_warn = models.PositiveIntegerField(
        default=50_000,
        help_text="When an assembly's input tokens exceed this, log a warning and badge the run",
    )
```

- [ ] **Step 2: Generate + apply migration**

```bash
python manage.py makemigrations voice
python manage.py migrate
```

- [ ] **Step 3: Smoke verify**

Run: `python manage.py shell -c "from voice.models import GlobalSettings; print(GlobalSettings.load().max_context_tokens_warn)"`
Expected: `50000`.

- [ ] **Step 4: Commit**

```bash
git add voice/models.py voice/migrations/0023_*.py
git commit -m "Add GlobalSettings.max_context_tokens_warn (assembler guardrail)"
```

---

### Task 7: Register new models in admin

**Files:**
- Modify: `voice/admin.py`

- [ ] **Step 1: Add admin registrations**

Open `voice/admin.py` and append at the bottom:

```python
from voice.models import GenerationRun, MegaPrompt, Scenario


@admin.register(MegaPrompt)
class MegaPromptAdmin(admin.ModelAdmin):
    list_display = ("domain", "name", "version", "is_active", "updated_at")
    list_filter = ("domain", "is_active")
    search_fields = ("name", "meta_prompt")
    readonly_fields = ("version", "created_at", "updated_at", "created_by")
    ordering = ("domain", "-version")

    def has_delete_permission(self, request, obj=None):
        # App-layer guard (spec §7): never delete the currently active version of any domain.
        # Deletion of non-active versions is allowed only via the per-object delete page.
        if obj is not None and obj.is_active:
            return False
        return super().has_delete_permission(request, obj)

    def get_actions(self, request):
        # Remove the bulk "delete selected" action so a careless admin can't wipe
        # multiple versions (including active ones) in one click.
        actions = super().get_actions(request)
        actions.pop("delete_selected", None)
        return actions


@admin.register(Scenario)
class ScenarioAdmin(admin.ModelAdmin):
    list_display = ("name", "slug", "is_active", "updated_at")
    list_filter = ("is_active",)
    search_fields = ("name", "slug", "description")
    prepopulated_fields = {"slug": ("name",)}


@admin.register(GenerationRun)
class GenerationRunAdmin(admin.ModelAdmin):
    list_display = ("created_at", "domain", "visit", "client", "success", "input_tokens", "output_tokens")
    list_filter = ("domain", "success", "triggered_by")
    search_fields = ("error", "claude_response")
    readonly_fields = [f.name for f in GenerationRun._meta.get_fields()]
    ordering = ("-created_at",)
```

- [ ] **Step 2: Smoke verify in browser**

Run dev server: `python manage.py runserver 0.0.0.0:8007`
Open `http://localhost:8007/admin/voice/` as a staff user.
Expected: `Mega prompts`, `Scenarios`, `Generation runs` all visible. Clicking each loads without error. `Scenarios` list has 5 starter rows.

Stop the server (Ctrl-C).

- [ ] **Step 3: Commit**

```bash
git add voice/admin.py
git commit -m "Register MegaPrompt, Scenario, GenerationRun in admin"
```

---

### Task 8: Seed files for the three mega-prompts (starter content)

**Files:**
- Create: `voice/management/commands/seed_data/mega_prompts/pre_call.txt`
- Create: `voice/management/commands/seed_data/mega_prompts/post_call.txt`
- Create: `voice/management/commands/seed_data/mega_prompts/lessons_distill.txt`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p voice/management/commands/seed_data/mega_prompts
```

- [ ] **Step 2: Write `pre_call.txt`**

Create `voice/management/commands/seed_data/mega_prompts/pre_call.txt` with the following content:

```
Ești un prompt engineer expert. Sarcina ta este să generezi DOUĂ texte pentru un agent vocal ElevenLabs (numit „Florina") care va suna agentul de vânzări ÎNAINTE de întâlnirea cu clientul, pentru a-l pregăti.

Răspunzi EXCLUSIV cu un obiect JSON valid, cu exact aceste două câmpuri:
- `body` — promptul complet de sistem pentru agentul vocal (între 600 și 900 cuvinte). Trebuie să conțină: identitatea Florinei, ce știe despre client (fapte specifice extrase din context), tonul, regulile de comportament, structura conversației cu 3-5 întrebări de verificare ramificate (corect / nu știe / greșit), regulile de închidere.
- `first_message` — prima frază pe care o spune Florina (15-25 cuvinte). În română, naturală, conține `{agent_first_name}` și `{client_name}`.

Niciun text înainte sau după JSON. Niciun backtick. Fără explicații.

## Date despre vizită
- Client: {client_name}
- Industrie: {client_industry}
- Scenariul vizitei: {scenario}
- Data și ora: {visit_time}
- Notele managerului (PRIORITATE MAXIMĂ — folosește-le ca sursă principală de adevăr): {manager_notes}

## Context client (rezumat AI)
{client_summary}

## Lecții din apelurile trecute pentru acest client
{client_lessons_learned}

## Metodologia recomandată
{methodology_summary}

## Istoricul de interacțiuni (CRM)
{interaction_history}

## Deal-urile active
{deal_history}

## Vizite anterioare pentru acest client
{client_past_visits}

## Vizite recente ale acestui agent (semnal mai slab — pentru a identifica obiceiuri)
{agent_recent_visits}

## Ce trebuie să generezi
Folosește limba ROMÂNĂ. Promptul (`body`) trebuie să fie scris ca un briefing personal, nu un template. Florina vorbește direct cu agentul ({agent_first_name}), nu cu clientul. Florina știe deja faptele despre client — pune întrebări naturale ca să verifice dacă agentul le știe, NU spune „știu deja". Dacă agentul greșește sau nu știe, corectează blând și oferă să-i trimiți informația pe email.

Lungimea totală a `body`: 600-900 cuvinte. Subtitluri simple, nu formatare excesivă. Fără markdown bold/italic. Nu repeta placeholder-urile {agent_first_name} și {client_name} mai des decât e necesar.
```

- [ ] **Step 3: Write `post_call.txt`**

Create `voice/management/commands/seed_data/mega_prompts/post_call.txt`:

```
Ești un prompt engineer expert. Sarcina ta este să generezi DOUĂ texte pentru un agent vocal ElevenLabs (numit „Florina") care va suna agentul de vânzări DUPĂ întâlnirea cu clientul, pentru debrief.

Răspunzi EXCLUSIV cu un obiect JSON valid, cu exact aceste două câmpuri:
- `body` — promptul complet pentru debrief (între 500 și 800 cuvinte). Structurat astfel: identitatea Florinei, întrebări scurte pentru a afla cum a decurs întâlnirea, ce s-a discutat efectiv față de brief-ul de pregătire, ce angajamente s-au luat, sentimentul clientului, pașii următori. Întotdeauna o singură întrebare odată. Empatic dacă a fost o întâlnire grea.
- `first_message` — prima frază (15-25 cuvinte) — în română, conține `{agent_first_name}` și `{client_name}`.

Niciun text înainte sau după JSON. Niciun backtick.

## Date despre vizită
- Client: {client_name}
- Industrie: {client_industry}
- Scenariul vizitei: {scenario}
- Data și ora: {visit_time}
- Notele managerului: {manager_notes}

## Brief-ul de pregătire pe care l-a primit agentul (referință)
{pre_call_brief}

## Transcript-ul întâlnirii (dacă există)
{visit_transcript}

## Context client
{client_summary}

## Lecții din apelurile trecute
{client_lessons_learned}

## Metodologia
{methodology_summary}

## Vizite anterioare pentru acest client
{client_past_visits}

## Ce trebuie să generezi
În română. Florina e supportivă, nu interogatorie. Întrebări scurte. Dacă transcript-ul există, folosește-l ca să pui întrebări specifice (nu generice). Dacă transcript-ul lipsește, întrebări mai deschise. Confirmă pașii următori la sfârșit.
```

- [ ] **Step 4: Write `lessons_distill.txt`**

Create `voice/management/commands/seed_data/mega_prompts/lessons_distill.txt`:

```
Ești un analist de vânzări. Sarcina ta: actualizezi blocul „lessons_learned" pentru un client, încorporând informația dintr-un nou apel post-întâlnire, RESPECTÂND eventuale editări manuale făcute de manager.

Răspunzi EXCLUSIV cu un obiect JSON valid cu un singur câmp:
- `lessons_learned` — blocul actualizat COMPLET (nu append; rescris cu noile informații integrate). Maxim 400 cuvinte. Distilat, fără elemente redundante, focus pe ce ar fi util în viitoarea pregătire de întâlnire.

Niciun text înainte sau după JSON. Niciun backtick.

## Lecțiile existente (pot conține editări manuale — RESPECTĂ-LE)
{current_lessons_learned}

## Noul rezumat post-întâlnire (sursa noilor informații)
{new_post_call_summary}

## Rezultatul evaluării (calificat, pierdut, follow-up etc.)
{evaluation_outcome}

## Reguli de distilare
1. Păstrează tot ce e în „lessons_learned" curent dacă pare scris manual (fraze idiomatice, opinii personale, instrucțiuni adresate viitorilor agenți) — sunt editări ale managerului.
2. Înglobează faptele noi din rezumat în blocul existent. Dacă un fapt nou contrazice unul vechi, păstrează versiunea mai recentă.
3. Elimină duplicate.
4. Limba — folosește limba dominantă din lecțiile existente (de obicei română).
5. Format — paragrafe scurte sau bullet-uri concise. Fără markdown bold/italic.
```

- [ ] **Step 5: Commit the seed files**

```bash
git add voice/management/commands/seed_data/mega_prompts/
git commit -m "Add seed files for the three mega-prompts (PRE/POST/DISTILL)"
```

---

### Task 9: `seed_mega_prompts` management command

**Files:**
- Create: `voice/management/commands/seed_mega_prompts.py`

- [ ] **Step 1: Create the command**

Create `voice/management/commands/seed_mega_prompts.py`:

```python
"""
seed_mega_prompts — idempotent bootstrap of MegaPrompt rows from seed files.

Reads voice/management/commands/seed_data/mega_prompts/{pre_call,post_call,lessons_distill}.txt
and ensures one active row per domain matching the file content.

Without --force: if an active row exists for a domain, leave it alone.
With --force: create a new version with the file content and activate it
              (atomically deactivates the previous active row).
"""

from pathlib import Path

from django.core.management.base import BaseCommand
from django.db import transaction
from django.db.models import Max

from voice.models import MegaPrompt


SEED_DIR = Path(__file__).parent / "seed_data" / "mega_prompts"

SEED_FILES = {
    MegaPrompt.Domain.PRE_CALL: "pre_call.txt",
    MegaPrompt.Domain.POST_CALL: "post_call.txt",
    MegaPrompt.Domain.LESSONS_DISTILL: "lessons_distill.txt",
}


class Command(BaseCommand):
    help = "Seed MegaPrompt rows from seed files. Idempotent without --force."

    def add_arguments(self, parser):
        parser.add_argument(
            "--force",
            action="store_true",
            help="Create a new active version even if one already exists.",
        )

    def handle(self, *args, **options):
        force = options["force"]
        for domain, filename in SEED_FILES.items():
            path = SEED_DIR / filename
            if not path.exists():
                self.stderr.write(self.style.ERROR(f"Missing seed file: {path}"))
                continue
            content = path.read_text(encoding="utf-8")

            with transaction.atomic():
                existing_active = (
                    MegaPrompt.objects.select_for_update()
                    .filter(domain=domain, is_active=True)
                    .first()
                )
                if existing_active and not force:
                    self.stdout.write(
                        f"[{domain}] active version already exists (v{existing_active.version}); skipping. "
                        f"Use --force to override."
                    )
                    continue

                max_v = (
                    MegaPrompt.objects.filter(domain=domain).aggregate(Max("version"))["version__max"] or 0
                )
                new_version = max_v + 1

                if existing_active:
                    existing_active.is_active = False
                    existing_active.save(update_fields=["is_active", "updated_at"])

                MegaPrompt.objects.create(
                    domain=domain,
                    name=f"Seeded v{new_version}",
                    meta_prompt=content,
                    is_active=True,
                    version=new_version,
                )
                self.stdout.write(
                    self.style.SUCCESS(
                        f"[{domain}] created v{new_version} from {filename} (active)"
                    )
                )
```

- [ ] **Step 2: Run on the empty DB**

Run: `python manage.py seed_mega_prompts`
Expected output: three lines indicating PRE_CALL v1, POST_CALL v1, LESSONS_DISTILL v1 were created.

- [ ] **Step 3: Run again to verify idempotency**

Run: `python manage.py seed_mega_prompts`
Expected output: three "skipping" lines.

- [ ] **Step 4: Verify with --force**

Run: `python manage.py seed_mega_prompts --force`
Expected output: three lines saying v2 created and active.

Run: `python manage.py shell -c "from voice.models import MegaPrompt; print(MegaPrompt.objects.values('domain', 'version', 'is_active'))"`
Expected: 6 rows total (v1 inactive + v2 active per domain).

- [ ] **Step 5: Commit**

```bash
git add voice/management/commands/seed_mega_prompts.py
git commit -m "Add seed_mega_prompts command (idempotent; --force re-seeds active)"
```

---

### Task 10: `export_mega_prompts` management command + service helper

**Files:**
- Create: `voice/management/commands/export_mega_prompts.py`

- [ ] **Step 1: Create the command**

Create `voice/management/commands/export_mega_prompts.py`:

```python
"""
export_mega_prompts — write the currently-active MegaPrompt rows back to seed files.

Inverse of seed_mega_prompts. Used as a safety net when auto-export-on-save
hasn't run (e.g., direct DB edit). Overwrites the seed files in place.
"""

from pathlib import Path

from django.core.management.base import BaseCommand

from voice.models import MegaPrompt

SEED_DIR = Path(__file__).parent / "seed_data" / "mega_prompts"

DOMAIN_TO_FILENAME = {
    MegaPrompt.Domain.PRE_CALL: "pre_call.txt",
    MegaPrompt.Domain.POST_CALL: "post_call.txt",
    MegaPrompt.Domain.LESSONS_DISTILL: "lessons_distill.txt",
}


class Command(BaseCommand):
    help = "Write the active MegaPrompt rows back to seed files."

    def handle(self, *args, **options):
        SEED_DIR.mkdir(parents=True, exist_ok=True)
        for domain, filename in DOMAIN_TO_FILENAME.items():
            active = MegaPrompt.objects.filter(domain=domain, is_active=True).first()
            if not active:
                self.stderr.write(self.style.WARNING(f"[{domain}] no active version; leaving {filename} as-is"))
                continue
            path = SEED_DIR / filename
            path.write_text(active.meta_prompt, encoding="utf-8")
            self.stdout.write(self.style.SUCCESS(f"[{domain}] wrote v{active.version} → {filename}"))
```

- [ ] **Step 2: Smoke verify**

Modify one of the seed files manually (e.g. add a comment to `pre_call.txt`). Then run:

```bash
python manage.py export_mega_prompts
git diff voice/management/commands/seed_data/mega_prompts/pre_call.txt
```

Expected: the file is overwritten with the active DB version (your manual edit is gone). This confirms the command is doing its job.

Revert: `git checkout -- voice/management/commands/seed_data/mega_prompts/pre_call.txt`

- [ ] **Step 3: Commit**

```bash
git add voice/management/commands/export_mega_prompts.py
git commit -m "Add export_mega_prompts command (writes active rows to seed files)"
```

---

### Task 11: Token usage tracking in `llm.py`

**Files:**
- Modify: `voice/services/llm.py`

- [ ] **Step 1: Add a token-returning variant of `_call_claude`**

In `voice/services/llm.py`, just after the existing `_call_claude` function (around line 89), add:

```python
def _call_claude_with_usage(
    system_prompt: str,
    user_message: str,
    max_tokens: int = 4096,
) -> tuple[str | None, int, int]:
    """Like _call_claude, but also returns (input_tokens, output_tokens).

    Returns (text_or_none, input_tokens, output_tokens). On failure, returns
    (None, 0, 0).
    """
    try:
        client = _get_client()
        response = client.messages.create(
            model=config("LLM_MODEL", default="claude-sonnet-4-20250514"),
            max_tokens=max_tokens,
            system=system_prompt,
            messages=[{"role": "user", "content": user_message}],
        )
        text = response.content[0].text
        in_tok = getattr(response.usage, "input_tokens", 0) or 0
        out_tok = getattr(response.usage, "output_tokens", 0) or 0
        return text, in_tok, out_tok
    except Exception as e:
        logger.error(f"Claude API call failed: {e}", exc_info=True)
        return None, 0, 0
```

- [ ] **Step 2: Smoke verify**

Run: `python manage.py shell`

Inside the shell:
```python
from voice.services.llm import _call_claude_with_usage, is_configured
if is_configured():
    text, i, o = _call_claude_with_usage("Reply with the single word: pong.", "ping", max_tokens=20)
    print(repr(text), i, o)
else:
    print("LLM not configured — skipping live call test")
```

Expected (if configured): `'pong'` (or close) and small token counts. Exit shell.

- [ ] **Step 3: Commit**

```bash
git add voice/services/llm.py
git commit -m "Add _call_claude_with_usage variant returning input/output token counts"
```

---

### Task 12: Context bundle builder

**Files:**
- Create: `voice/services/prompt_context.py`

- [ ] **Step 1: Create the module**

Create `voice/services/prompt_context.py`:

```python
"""
Context-bundle assembly for the Auto Prompt Assembler.

Builds a dict of placeholders → values from a Visit (or Client, for LESSONS_DISTILL).
Used by voice/services/assembler.py and voice/services/lessons.py.
"""

from __future__ import annotations

import logging
from typing import Any

from voice.models import Client, Visit

logger = logging.getLogger(__name__)


def _format_interaction_history(interactions: list[dict] | None) -> str:
    if not interactions:
        return ""
    lines = []
    for it in interactions[:5]:
        kind = it.get("type", "note")
        date = it.get("date", "")
        content = (it.get("content") or "")[:200]
        lines.append(f"- [{kind}] {date}: {content}")
    return "\n".join(lines)


def _format_deal_history(deals: list[dict] | None) -> str:
    if not deals:
        return ""
    lines = []
    for d in deals[:3]:
        title = d.get("title", "Untitled")
        status = d.get("status", "unknown")
        lines.append(f"- {title} (status: {status})")
    return "\n".join(lines)


def _format_past_visits(visits) -> str:
    """visits is an iterable of Visit instances."""
    if not visits:
        return ""
    lines = []
    for v in visits:
        date = v.start_time.strftime("%Y-%m-%d") if v.start_time else "?"
        summary = (v.post_call_summary or "").strip()
        if summary:
            lines.append(f"- {date} · {v.title}\n  {summary[:400]}")
        else:
            lines.append(f"- {date} · {v.title} (no debrief)")
    return "\n".join(lines)


def build_pre_call_context(visit: Visit) -> dict[str, Any]:
    """Return placeholder→value dict for a PRE_CALL assembly."""
    client = visit.client
    methodology = visit.get_effective_methodology()
    past_client_visits = (
        Visit.objects.filter(client=client)
        .exclude(pk=visit.pk)
        .order_by("-start_time")[:3]
    )
    past_agent_visits = (
        Visit.objects.filter(agent=visit.agent)
        .exclude(pk=visit.pk)
        .order_by("-start_time")[:5]
    )

    return {
        "agent_first_name": visit.agent.first_name or visit.agent.username,
        "client_name": client.name,
        "client_industry": client.industry or "",
        "client_summary": client.ai_summary or "",
        "client_lessons_learned": client.lessons_learned or "",
        "visit_time": visit.start_time.strftime("%d %B %Y, %H:%M") if visit.start_time else "",
        "scenario": visit.scenario.name if visit.scenario_id else "",
        "manager_notes": visit.manager_notes or "",
        "methodology_summary": (methodology.ai_summary if methodology else "") or "",
        "interaction_history": _format_interaction_history(client.interaction_history),
        "deal_history": _format_deal_history(client.deal_history),
        "client_past_visits": _format_past_visits(past_client_visits),
        "agent_recent_visits": _format_past_visits(past_agent_visits),
    }


def build_post_call_context(visit: Visit, transcript: str = "") -> dict[str, Any]:
    """Return placeholder→value dict for a POST_CALL assembly.

    `transcript` is the meeting transcript (if available — may be empty).
    """
    base = build_pre_call_context(visit)
    base["pre_call_brief"] = visit.pre_call_prompt or ""
    base["visit_transcript"] = transcript or ""
    return base


def build_lessons_context(
    client: Client,
    new_post_call_summary: str,
    evaluation_outcome: str,
) -> dict[str, Any]:
    """Return placeholder→value dict for a LESSONS_DISTILL run."""
    return {
        "current_lessons_learned": client.lessons_learned or "",
        "new_post_call_summary": new_post_call_summary or "",
        "evaluation_outcome": evaluation_outcome or "",
    }


def render_placeholders(template: str, values: dict[str, Any]) -> str:
    """Substitute {placeholder} tokens in `template` with values from `values`.

    Unknown placeholders are left in place and logged at WARNING.
    """
    import re

    pattern = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}")
    seen_unknown: set[str] = set()

    def repl(match: re.Match) -> str:
        key = match.group(1)
        if key in values:
            return str(values[key]) if values[key] is not None else ""
        if key not in seen_unknown:
            seen_unknown.add(key)
            logger.warning("render_placeholders: unknown placeholder {%s} left untouched", key)
        return match.group(0)

    return pattern.sub(repl, template)
```

- [ ] **Step 2: Write local-only tests**

Create `voice/_tests_local/test_prompt_context.py`:

```python
"""Local-only tests for prompt_context — never committed."""

from django.test import TestCase
from django.utils import timezone

from voice.models import Client, Scenario, User, Visit
from voice.services.prompt_context import (
    build_lessons_context,
    build_pre_call_context,
    render_placeholders,
)


class PromptContextTests(TestCase):
    def setUp(self):
        self.agent = User.objects.create_user(username="alex", first_name="Alex", password="x")
        self.client_obj = Client.objects.create(
            name="ACME SRL",
            industry="construction",
            ai_summary="An ACME summary.",
            interaction_history=[
                {"type": "call", "date": "2026-05-01", "content": "First chat"},
            ],
            deal_history=[{"title": "Big deal", "status": "open"}],
            lessons_learned="Manager said: focus on price.",
        )
        self.scenario = Scenario.objects.create(name="Discovery", slug="discovery")
        self.visit = Visit.objects.create(
            agent=self.agent,
            client=self.client_obj,
            title="ACME discovery",
            start_time=timezone.now(),
            end_time=timezone.now(),
            scenario=self.scenario,
            manager_notes="Push on timeline.",
        )

    def test_pre_call_context_has_expected_keys(self):
        ctx = build_pre_call_context(self.visit)
        for key in (
            "agent_first_name", "client_name", "client_industry", "client_summary",
            "client_lessons_learned", "visit_time", "scenario", "manager_notes",
            "methodology_summary", "interaction_history", "deal_history",
            "client_past_visits", "agent_recent_visits",
        ):
            self.assertIn(key, ctx)
        self.assertEqual(ctx["client_name"], "ACME SRL")
        self.assertEqual(ctx["scenario"], "Discovery")
        self.assertEqual(ctx["client_lessons_learned"], "Manager said: focus on price.")

    def test_render_substitutes_known_placeholders(self):
        out = render_placeholders("Hello {agent_first_name}, meeting at {visit_time}.", {
            "agent_first_name": "Alex",
            "visit_time": "10:00",
        })
        self.assertEqual(out, "Hello Alex, meeting at 10:00.")

    def test_render_leaves_unknown_placeholders(self):
        out = render_placeholders("Hi {unknown_field} world", {"x": "y"})
        self.assertEqual(out, "Hi {unknown_field} world")

    def test_lessons_context_keys(self):
        ctx = build_lessons_context(self.client_obj, "new summary", "qualified")
        self.assertEqual(ctx["current_lessons_learned"], "Manager said: focus on price.")
        self.assertEqual(ctx["new_post_call_summary"], "new summary")
        self.assertEqual(ctx["evaluation_outcome"], "qualified")
```

- [ ] **Step 3: Run the local tests**

Run: `python manage.py test voice._tests_local.test_prompt_context -v 2`
Expected: 4 tests pass.

- [ ] **Step 4: Verify the tests are NOT staged**

Run: `git status --short`
Expected: only `voice/services/prompt_context.py` shows as untracked/modified. `voice/_tests_local/*` does NOT appear.

- [ ] **Step 5: Commit ONLY the service file**

```bash
git add voice/services/prompt_context.py
git commit -m "Add prompt_context service (context bundle + placeholder rendering)"
```

---

### Task 13: Assembler service — happy path, locks, JSON parse, missing template

**Files:**
- Create: `voice/services/assembler.py`

- [ ] **Step 1: Create the assembler**

Create `voice/services/assembler.py`:

```python
"""
Auto Prompt Assembler.

Two public entry points:
- assemble_pre_call(visit, triggered_by, user=None) -> GenerationRun
- assemble_post_call(visit, transcript="", triggered_by="MANUAL", user=None) -> GenerationRun

Each entry point:
  1. Loads the active MegaPrompt for its domain. If none exists -> failed run.
  2. Builds the context bundle.
  3. Renders placeholders.
  4. If all target fields are locked, skips the Claude call and records the skip.
  5. Calls Claude with token tracking.
  6. Parses JSON {body, first_message}. On parse error -> failed run.
  7. Writes only the unlocked target fields on the Visit.
  8. Records a GenerationRun row.

All exceptions are caught and surfaced via GenerationRun.error.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from voice.models import GenerationRun, GlobalSettings, MegaPrompt, Visit
from voice.services.llm import _call_claude_with_usage, is_configured
from voice.services.prompt_context import (
    build_post_call_context,
    build_pre_call_context,
    render_placeholders,
)

logger = logging.getLogger(__name__)


def _load_active(domain: str) -> MegaPrompt | None:
    return MegaPrompt.objects.filter(domain=domain, is_active=True).first()


def _parse_response(raw: str) -> dict[str, Any]:
    """Parse JSON {body, first_message} from Claude's response.

    Tolerates fenced markdown (```json ... ```) and stray whitespace.
    Raises ValueError on unrecoverable failure.
    """
    text = (raw or "").strip()
    # Strip code fences if present
    if text.startswith("```"):
        text = text.strip("`")
        # Often starts with "json\n" after fence — drop the leading language tag if any
        if "\n" in text:
            first_line, rest = text.split("\n", 1)
            if first_line.strip().lower() in {"json", "json5"}:
                text = rest
        text = text.strip()
        if text.endswith("```"):
            text = text[:-3].strip()
    parsed = json.loads(text)
    if not isinstance(parsed, dict):
        raise ValueError("Claude response was JSON but not an object")
    return parsed


def _record_run(
    *,
    visit: Visit | None,
    client=None,
    domain: str,
    mega_prompt: MegaPrompt | None,
    triggered_by: str,
    user,
    context_bundle: dict[str, Any],
    claude_request: str,
    claude_response: str,
    parsed_outputs: dict[str, Any],
    input_tokens: int,
    output_tokens: int,
    success: bool,
    error: str,
) -> GenerationRun:
    settings = GlobalSettings.load()
    if input_tokens > settings.max_context_tokens_warn:
        logger.warning(
            "Assembler run used %d input tokens (> %d warn threshold) for visit=%s domain=%s",
            input_tokens, settings.max_context_tokens_warn, getattr(visit, "pk", None), domain,
        )
        context_bundle = {**context_bundle, "large_context": True}
    return GenerationRun.objects.create(
        visit=visit,
        client=client,
        domain=domain,
        mega_prompt=mega_prompt,
        triggered_by=triggered_by,
        context_bundle=context_bundle,
        claude_request=claude_request,
        claude_response=claude_response,
        parsed_outputs=parsed_outputs,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        success=success,
        error=error,
        created_by=user if user and user.is_authenticated else None,
    )


def assemble_pre_call(
    visit: Visit,
    triggered_by: str = GenerationRun.TriggeredBy.MANUAL,
    user=None,
) -> GenerationRun:
    """Assemble pre_call_prompt + pre_call_first_message for a Visit."""
    domain = MegaPrompt.Domain.PRE_CALL
    mega = _load_active(domain)
    if mega is None:
        return _record_run(
            visit=visit, domain=domain, mega_prompt=None, triggered_by=triggered_by,
            user=user, context_bundle={}, claude_request="", claude_response="",
            parsed_outputs={}, input_tokens=0, output_tokens=0,
            success=False, error="No active MegaPrompt for PRE_CALL",
        )

    ctx = build_pre_call_context(visit)
    rendered = render_placeholders(mega.meta_prompt, ctx)

    # Lock check — refuse the Claude call entirely if both target fields are locked.
    if visit.pre_call_prompt_locked and visit.pre_call_first_message_locked:
        return _record_run(
            visit=visit, domain=domain, mega_prompt=mega, triggered_by=triggered_by,
            user=user,
            context_bundle={**ctx, "skipped_reason": "both fields locked"},
            claude_request=rendered, claude_response="", parsed_outputs={},
            input_tokens=0, output_tokens=0,
            success=True, error="",
        )

    if not is_configured():
        return _record_run(
            visit=visit, domain=domain, mega_prompt=mega, triggered_by=triggered_by,
            user=user, context_bundle=ctx, claude_request=rendered, claude_response="",
            parsed_outputs={}, input_tokens=0, output_tokens=0,
            success=False, error="LLM not configured",
        )

    raw, in_tok, out_tok = _call_claude_with_usage(
        system_prompt="You return ONLY a JSON object with the requested fields. No prose.",
        user_message=rendered,
        max_tokens=4096,
    )
    if raw is None:
        return _record_run(
            visit=visit, domain=domain, mega_prompt=mega, triggered_by=triggered_by,
            user=user, context_bundle=ctx, claude_request=rendered, claude_response="",
            parsed_outputs={}, input_tokens=in_tok, output_tokens=out_tok,
            success=False, error="Claude API call returned None",
        )

    try:
        parsed = _parse_response(raw)
    except (ValueError, json.JSONDecodeError) as e:
        return _record_run(
            visit=visit, domain=domain, mega_prompt=mega, triggered_by=triggered_by,
            user=user, context_bundle=ctx, claude_request=rendered, claude_response=raw,
            parsed_outputs={}, input_tokens=in_tok, output_tokens=out_tok,
            success=False, error=f"JSON parse error: {e}",
        )

    body = parsed.get("body", "")
    first_message = parsed.get("first_message", "")

    updates: list[str] = []
    if not visit.pre_call_prompt_locked and isinstance(body, str) and body:
        visit.pre_call_prompt = body
        updates.append("pre_call_prompt")
    if not visit.pre_call_first_message_locked and isinstance(first_message, str) and first_message:
        visit.pre_call_first_message = first_message
        updates.append("pre_call_first_message")
    if updates:
        updates.append("updated_at")
        visit.save(update_fields=updates)

    return _record_run(
        visit=visit, domain=domain, mega_prompt=mega, triggered_by=triggered_by,
        user=user, context_bundle=ctx, claude_request=rendered, claude_response=raw,
        parsed_outputs=parsed, input_tokens=in_tok, output_tokens=out_tok,
        success=True, error="",
    )


def assemble_post_call(
    visit: Visit,
    transcript: str = "",
    triggered_by: str = GenerationRun.TriggeredBy.MANUAL,
    user=None,
) -> GenerationRun:
    """Assemble post_call_prompt + post_call_first_message for a Visit."""
    domain = MegaPrompt.Domain.POST_CALL
    mega = _load_active(domain)
    if mega is None:
        return _record_run(
            visit=visit, domain=domain, mega_prompt=None, triggered_by=triggered_by,
            user=user, context_bundle={}, claude_request="", claude_response="",
            parsed_outputs={}, input_tokens=0, output_tokens=0,
            success=False, error="No active MegaPrompt for POST_CALL",
        )

    ctx = build_post_call_context(visit, transcript=transcript)
    rendered = render_placeholders(mega.meta_prompt, ctx)

    if visit.post_call_prompt_locked and visit.post_call_first_message_locked:
        return _record_run(
            visit=visit, domain=domain, mega_prompt=mega, triggered_by=triggered_by,
            user=user,
            context_bundle={**ctx, "skipped_reason": "both fields locked"},
            claude_request=rendered, claude_response="", parsed_outputs={},
            input_tokens=0, output_tokens=0,
            success=True, error="",
        )

    if not is_configured():
        return _record_run(
            visit=visit, domain=domain, mega_prompt=mega, triggered_by=triggered_by,
            user=user, context_bundle=ctx, claude_request=rendered, claude_response="",
            parsed_outputs={}, input_tokens=0, output_tokens=0,
            success=False, error="LLM not configured",
        )

    raw, in_tok, out_tok = _call_claude_with_usage(
        system_prompt="You return ONLY a JSON object with the requested fields. No prose.",
        user_message=rendered,
        max_tokens=4096,
    )
    if raw is None:
        return _record_run(
            visit=visit, domain=domain, mega_prompt=mega, triggered_by=triggered_by,
            user=user, context_bundle=ctx, claude_request=rendered, claude_response="",
            parsed_outputs={}, input_tokens=in_tok, output_tokens=out_tok,
            success=False, error="Claude API call returned None",
        )

    try:
        parsed = _parse_response(raw)
    except (ValueError, json.JSONDecodeError) as e:
        return _record_run(
            visit=visit, domain=domain, mega_prompt=mega, triggered_by=triggered_by,
            user=user, context_bundle=ctx, claude_request=rendered, claude_response=raw,
            parsed_outputs={}, input_tokens=in_tok, output_tokens=out_tok,
            success=False, error=f"JSON parse error: {e}",
        )

    body = parsed.get("body", "")
    first_message = parsed.get("first_message", "")
    updates: list[str] = []
    if not visit.post_call_prompt_locked and isinstance(body, str) and body:
        visit.post_call_prompt = body
        updates.append("post_call_prompt")
    if not visit.post_call_first_message_locked and isinstance(first_message, str) and first_message:
        visit.post_call_first_message = first_message
        updates.append("post_call_first_message")
    if updates:
        updates.append("updated_at")
        visit.save(update_fields=updates)

    return _record_run(
        visit=visit, domain=domain, mega_prompt=mega, triggered_by=triggered_by,
        user=user, context_bundle=ctx, claude_request=rendered, claude_response=raw,
        parsed_outputs=parsed, input_tokens=in_tok, output_tokens=out_tok,
        success=True, error="",
    )
```

- [ ] **Step 2: Write local-only tests for the assembler**

Create `voice/_tests_local/test_assembler.py`:

```python
"""Local-only tests for assembler — never committed."""

from unittest.mock import patch

from django.test import TestCase
from django.utils import timezone

from voice.models import Client, GenerationRun, MegaPrompt, User, Visit
from voice.services import assembler


def _make_active_prompt(domain, body="{client_name} {agent_first_name}"):
    return MegaPrompt.objects.create(
        domain=domain, name="test", meta_prompt=body, is_active=True, version=1,
    )


class AssemblerTests(TestCase):
    def setUp(self):
        self.agent = User.objects.create_user(username="alex", first_name="Alex", password="x")
        self.client_obj = Client.objects.create(name="ACME")
        self.visit = Visit.objects.create(
            agent=self.agent, client=self.client_obj, title="V",
            start_time=timezone.now(), end_time=timezone.now(),
        )

    def test_missing_active_megaprompt_creates_failed_run(self):
        run = assembler.assemble_pre_call(self.visit)
        self.assertFalse(run.success)
        self.assertIn("No active MegaPrompt", run.error)

    @patch("voice.services.assembler._call_claude_with_usage")
    @patch("voice.services.assembler.is_configured", return_value=True)
    def test_happy_path_writes_both_fields(self, _is_cfg, mock_call):
        _make_active_prompt(MegaPrompt.Domain.PRE_CALL)
        mock_call.return_value = (
            '{"body": "BODY-TEXT", "first_message": "FIRST-MSG"}', 100, 50,
        )
        run = assembler.assemble_pre_call(self.visit)
        self.assertTrue(run.success)
        self.visit.refresh_from_db()
        self.assertEqual(self.visit.pre_call_prompt, "BODY-TEXT")
        self.assertEqual(self.visit.pre_call_first_message, "FIRST-MSG")
        self.assertEqual(run.input_tokens, 100)
        self.assertEqual(run.output_tokens, 50)

    @patch("voice.services.assembler._call_claude_with_usage")
    @patch("voice.services.assembler.is_configured", return_value=True)
    def test_both_locked_skips_claude_and_records_skip(self, _is_cfg, mock_call):
        _make_active_prompt(MegaPrompt.Domain.PRE_CALL)
        self.visit.pre_call_prompt_locked = True
        self.visit.pre_call_first_message_locked = True
        self.visit.save()
        run = assembler.assemble_pre_call(self.visit)
        self.assertTrue(run.success)
        mock_call.assert_not_called()
        self.assertEqual(run.context_bundle.get("skipped_reason"), "both fields locked")

    @patch("voice.services.assembler._call_claude_with_usage")
    @patch("voice.services.assembler.is_configured", return_value=True)
    def test_partial_lock_writes_only_unlocked(self, _is_cfg, mock_call):
        _make_active_prompt(MegaPrompt.Domain.PRE_CALL)
        self.visit.pre_call_prompt = "OLD-BODY"
        self.visit.pre_call_prompt_locked = True
        self.visit.save()
        mock_call.return_value = (
            '{"body": "NEW-BODY", "first_message": "NEW-FIRST"}', 10, 10,
        )
        assembler.assemble_pre_call(self.visit)
        self.visit.refresh_from_db()
        self.assertEqual(self.visit.pre_call_prompt, "OLD-BODY")  # untouched
        self.assertEqual(self.visit.pre_call_first_message, "NEW-FIRST")

    @patch("voice.services.assembler._call_claude_with_usage")
    @patch("voice.services.assembler.is_configured", return_value=True)
    def test_bad_json_creates_failed_run(self, _is_cfg, mock_call):
        _make_active_prompt(MegaPrompt.Domain.PRE_CALL)
        mock_call.return_value = ("not json at all", 10, 5)
        run = assembler.assemble_pre_call(self.visit)
        self.assertFalse(run.success)
        self.assertIn("JSON parse error", run.error)

    @patch("voice.services.assembler._call_claude_with_usage")
    @patch("voice.services.assembler.is_configured", return_value=True)
    def test_post_call_writes_post_fields(self, _is_cfg, mock_call):
        _make_active_prompt(MegaPrompt.Domain.POST_CALL)
        mock_call.return_value = (
            '{"body": "POST-BODY", "first_message": "POST-FIRST"}', 10, 5,
        )
        run = assembler.assemble_post_call(self.visit, transcript="hello")
        self.assertTrue(run.success)
        self.visit.refresh_from_db()
        self.assertEqual(self.visit.post_call_prompt, "POST-BODY")
        self.assertEqual(self.visit.post_call_first_message, "POST-FIRST")

    def test_parse_response_strips_code_fences(self):
        raw = '```json\n{"body": "x", "first_message": "y"}\n```'
        parsed = assembler._parse_response(raw)
        self.assertEqual(parsed["body"], "x")
        self.assertEqual(parsed["first_message"], "y")
```

- [ ] **Step 3: Run the local tests**

Run: `python manage.py test voice._tests_local.test_assembler -v 2`
Expected: 7 tests pass.

- [ ] **Step 4: Verify tests are not staged**

Run: `git status --short`
Expected: only `voice/services/assembler.py` shows as untracked.

- [ ] **Step 5: Commit the service**

```bash
git add voice/services/assembler.py
git commit -m "Add assembler (pre/post call); per-field locks, JSON parse, token tracking"
```

---

### Task 14: Lessons distiller

**Files:**
- Create: `voice/services/lessons.py`

- [ ] **Step 1: Create the module**

Create `voice/services/lessons.py`:

```python
"""
LESSONS_DISTILL — closed-loop update of Client.lessons_learned after every post-call.

Public entry point:
    distill_lessons(client, new_post_call_summary, evaluation_outcome,
                    triggered_by="END_OF_MEETING", user=None) -> GenerationRun
"""

from __future__ import annotations

import json
import logging

from voice.models import Client, GenerationRun, MegaPrompt
from voice.services.assembler import _parse_response, _record_run
from voice.services.llm import _call_claude_with_usage, is_configured
from voice.services.prompt_context import build_lessons_context, render_placeholders

logger = logging.getLogger(__name__)


def distill_lessons(
    client: Client,
    new_post_call_summary: str,
    evaluation_outcome: str,
    triggered_by: str = GenerationRun.TriggeredBy.END_OF_MEETING,
    user=None,
) -> GenerationRun:
    domain = MegaPrompt.Domain.LESSONS_DISTILL
    mega = MegaPrompt.objects.filter(domain=domain, is_active=True).first()
    if mega is None:
        return _record_run(
            visit=None, client=client, domain=domain, mega_prompt=None,
            triggered_by=triggered_by, user=user, context_bundle={},
            claude_request="", claude_response="", parsed_outputs={},
            input_tokens=0, output_tokens=0,
            success=False, error="No active MegaPrompt for LESSONS_DISTILL",
        )

    ctx = build_lessons_context(client, new_post_call_summary, evaluation_outcome)
    rendered = render_placeholders(mega.meta_prompt, ctx)

    if not is_configured():
        return _record_run(
            visit=None, client=client, domain=domain, mega_prompt=mega,
            triggered_by=triggered_by, user=user, context_bundle=ctx,
            claude_request=rendered, claude_response="", parsed_outputs={},
            input_tokens=0, output_tokens=0,
            success=False, error="LLM not configured",
        )

    raw, in_tok, out_tok = _call_claude_with_usage(
        system_prompt="You return ONLY a JSON object with the requested fields. No prose.",
        user_message=rendered,
        max_tokens=2048,
    )
    if raw is None:
        return _record_run(
            visit=None, client=client, domain=domain, mega_prompt=mega,
            triggered_by=triggered_by, user=user, context_bundle=ctx,
            claude_request=rendered, claude_response="", parsed_outputs={},
            input_tokens=in_tok, output_tokens=out_tok,
            success=False, error="Claude API call returned None",
        )

    try:
        parsed = _parse_response(raw)
    except (ValueError, json.JSONDecodeError) as e:
        return _record_run(
            visit=None, client=client, domain=domain, mega_prompt=mega,
            triggered_by=triggered_by, user=user, context_bundle=ctx,
            claude_request=rendered, claude_response=raw, parsed_outputs={},
            input_tokens=in_tok, output_tokens=out_tok,
            success=False, error=f"JSON parse error: {e}",
        )

    new_lessons = parsed.get("lessons_learned", "")
    if isinstance(new_lessons, str) and new_lessons:
        client.lessons_learned = new_lessons
        client.save(update_fields=["lessons_learned", "updated_at"])

    return _record_run(
        visit=None, client=client, domain=domain, mega_prompt=mega,
        triggered_by=triggered_by, user=user, context_bundle=ctx,
        claude_request=rendered, claude_response=raw, parsed_outputs=parsed,
        input_tokens=in_tok, output_tokens=out_tok,
        success=True, error="",
    )
```

- [ ] **Step 2: Write local-only test**

Create `voice/_tests_local/test_lessons.py`:

```python
"""Local-only tests for lessons distiller — never committed."""

from unittest.mock import patch

from django.test import TestCase

from voice.models import Client, MegaPrompt
from voice.services import lessons


class LessonsDistillTests(TestCase):
    def setUp(self):
        self.client_obj = Client.objects.create(
            name="ACME", lessons_learned="Old lesson.",
        )
        MegaPrompt.objects.create(
            domain=MegaPrompt.Domain.LESSONS_DISTILL,
            name="t",
            meta_prompt="Existing: {current_lessons_learned}\nNew: {new_post_call_summary}",
            is_active=True, version=1,
        )

    def test_missing_prompt_creates_failed_run(self):
        MegaPrompt.objects.all().delete()
        run = lessons.distill_lessons(self.client_obj, "new", "qualified")
        self.assertFalse(run.success)

    @patch("voice.services.lessons._call_claude_with_usage")
    @patch("voice.services.lessons.is_configured", return_value=True)
    def test_happy_path_updates_client(self, _cfg, mock_call):
        mock_call.return_value = (
            '{"lessons_learned": "Old lesson. Also: care about timeline."}', 50, 20,
        )
        run = lessons.distill_lessons(self.client_obj, "Customer mentioned timeline.", "qualified")
        self.assertTrue(run.success)
        self.client_obj.refresh_from_db()
        self.assertIn("timeline", self.client_obj.lessons_learned)

    @patch("voice.services.lessons._call_claude_with_usage")
    @patch("voice.services.lessons.is_configured", return_value=True)
    def test_empty_response_does_not_blank_field(self, _cfg, mock_call):
        mock_call.return_value = ('{"lessons_learned": ""}', 10, 5)
        lessons.distill_lessons(self.client_obj, "x", "y")
        self.client_obj.refresh_from_db()
        self.assertEqual(self.client_obj.lessons_learned, "Old lesson.")
```

- [ ] **Step 3: Run tests**

Run: `python manage.py test voice._tests_local.test_lessons -v 2`
Expected: 3 tests pass.

- [ ] **Step 4: Commit the service**

```bash
git add voice/services/lessons.py
git commit -m "Add lessons distiller (closed-loop Client.lessons_learned update)"
```

---

### Task 15: Wire `tasks.py` PRE_CALL path to the new assembler

**Files:**
- Modify: `voice/tasks.py` (around lines 798, 832)
- Modify: `voice/services/__init__.py` (drop old exports, add new)

- [ ] **Step 1: Replace the import + call site for PRE_CALL**

Open `voice/tasks.py`. Find line 798 (the import of `generate_pre_call_prompt`). Replace:

```python
    from .services.prompt_builder import generate_pre_call_prompt
```

with:

```python
    from .models import GenerationRun
    from .services.assembler import assemble_pre_call
```

Find line ~832 where `prompt = generate_pre_call_prompt(visit)` is called. Replace that line and the immediately following `if not prompt:` block. The new code:

```python
                run = assemble_pre_call(
                    visit,
                    triggered_by=GenerationRun.TriggeredBy.SCHEDULED,
                )
                if not run.success:
                    logger.error(
                        f"Failed to generate pre-call prompt for visit {visit.id}: {run.error}"
                    )
                    continue
                prompt = visit.pre_call_prompt
                if not prompt:
                    logger.error(
                        f"Pre-call prompt empty after assembly for visit {visit.id}"
                    )
                    continue
```

- [ ] **Step 2: Update `voice/services/__init__.py`**

Open `voice/services/__init__.py`. Locate line 92:

```python
from .prompt_builder import generate_post_call_prompt, generate_pre_call_prompt
```

Replace with:

```python
from .assembler import assemble_post_call, assemble_pre_call
from .lessons import distill_lessons
```

Locate the `__all__` block (around lines 168-169) that contains `"generate_pre_call_prompt"` and `"generate_post_call_prompt"`. Replace those two strings with:

```python
    "assemble_pre_call",
    "assemble_post_call",
    "distill_lessons",
```

- [ ] **Step 3: Smoke verify imports load**

Run: `python manage.py shell -c "from voice.services import assemble_pre_call, assemble_post_call, distill_lessons; print('OK')"`
Expected: `OK`.

Run: `python manage.py check`
Expected: `System check identified no issues (0 silenced).`

- [ ] **Step 4: Commit**

```bash
git add voice/tasks.py voice/services/__init__.py
git commit -m "Wire scheduled PRE_CALL path through new assembler"
```

---

### Task 16: Wire `tasks.py` POST_CALL path + chain LESSONS_DISTILL

**Files:**
- Modify: `voice/tasks.py` (around lines 889, 915, and `process_visit_post_call_completion`)

- [ ] **Step 1: Replace the POST_CALL import + call site**

In `voice/tasks.py` around line 889 find:

```python
    from .services.prompt_builder import generate_post_call_prompt
```

Replace with:

```python
    from .models import GenerationRun
    from .services.assembler import assemble_post_call
```

Around line 915 where `prompt = generate_post_call_prompt(visit)` is called, replace that line and any subsequent `if not prompt:` block, mirroring Task 15:

```python
                run = assemble_post_call(
                    visit,
                    transcript="",  # transcript may be empty pre-call; webhook chain handles fresh transcript
                    triggered_by=GenerationRun.TriggeredBy.SCHEDULED,
                )
                if not run.success:
                    logger.error(
                        f"Failed to generate post-call prompt for visit {visit.id}: {run.error}"
                    )
                    continue
                prompt = visit.post_call_prompt
                if not prompt:
                    logger.error(
                        f"Post-call prompt empty after assembly for visit {visit.id}"
                    )
                    continue
```

- [ ] **Step 2: Chain LESSONS_DISTILL in `process_visit_post_call_completion`**

Open `voice/tasks.py` and find `def process_visit_post_call_completion` around line 957. This function runs after a post-call CallAttempt completes — it should be where we now also trigger lessons distillation.

Locate the place where `visit.post_call_summary` is finalised (search for `post_call_summary`). Immediately after the summary is saved, add:

```python
            # Closed-loop: distill new lessons into the client memory
            try:
                from .services.lessons import distill_lessons

                distill_lessons(
                    client=visit.client,
                    new_post_call_summary=visit.post_call_summary or "",
                    evaluation_outcome=getattr(call_attempt, "outcome", "") or "",
                )
            except Exception:
                logger.exception(
                    "distill_lessons failed for visit=%s — not raising (debrief still complete)",
                    visit.id,
                )
```

(Wrapping in try/except prevents a distill failure from breaking the post-call success path.)

- [ ] **Step 3: Smoke verify imports + system check**

```bash
python manage.py check
python manage.py shell -c "from voice.tasks import process_visit_post_calls, process_visit_post_call_completion; print('OK')"
```

Expected: `0 issues` then `OK`.

- [ ] **Step 4: Commit**

```bash
git add voice/tasks.py
git commit -m "Wire scheduled POST_CALL + chain LESSONS_DISTILL after debrief"
```

---

### Task 17: Mega-prompt list view + URL + template

**Files:**
- Modify: `voice/views.py`
- Modify: `voice/urls.py`
- Create: `voice/templates/voice/mega_prompt_list.html`

- [ ] **Step 1: Add a `_StaffRequiredMixin` if missing, plus the list view**

Open `voice/views.py`. At the top of the file (after existing imports) ensure:

```python
from django.contrib.auth.mixins import LoginRequiredMixin, UserPassesTestMixin
```

Append at the bottom of the file:

```python
class _StaffRequiredMixin(LoginRequiredMixin, UserPassesTestMixin):
    def test_func(self):
        return self.request.user.is_staff


from django.views.generic import ListView

from voice.models import MegaPrompt as _MegaPromptModel


class MegaPromptListView(_StaffRequiredMixin, ListView):
    model = _MegaPromptModel
    template_name = "voice/mega_prompt_list.html"
    context_object_name = "templates"

    def get_queryset(self):
        return _MegaPromptModel.objects.order_by("domain", "-version")

    def get_context_data(self, **kwargs):
        ctx = super().get_context_data(**kwargs)
        ctx["domains"] = _MegaPromptModel.Domain.choices
        ctx["active_per_domain"] = {
            mp.domain: mp for mp in _MegaPromptModel.objects.filter(is_active=True)
        }
        return ctx
```

- [ ] **Step 2: Add the template**

Create `voice/templates/voice/mega_prompt_list.html`:

```html
{% extends "voice/base.html" %}
{% block content %}
<h1>Mega prompts</h1>
<p class="subtitle">One active version per domain. Edit creates a new version. Seed files in <code>voice/management/commands/seed_data/mega_prompts/</code> mirror the active rows.</p>

{% for domain_code, domain_label in domains %}
  <section class="mega-prompt-domain">
    <h2>{{ domain_label }}</h2>
    {% with active=active_per_domain|default_if_none:""|stringformat:"s" %}
      {% if active_per_domain|dictsort:0 %}{% endif %}
    {% endwith %}
    <div class="actions">
      <a class="btn" href="{% url 'voice:mega-prompt-create' %}?domain={{ domain_code }}">+ New version</a>
    </div>
    <table class="data-table">
      <thead>
        <tr><th>Version</th><th>Name</th><th>Active</th><th>Updated</th><th>Actions</th></tr>
      </thead>
      <tbody>
        {% for tpl in templates %}
          {% if tpl.domain == domain_code %}
            <tr class="{% if tpl.is_active %}is-active{% endif %}">
              <td>v{{ tpl.version }}</td>
              <td>{{ tpl.name }}</td>
              <td>{% if tpl.is_active %}✓ active{% else %}—{% endif %}</td>
              <td>{{ tpl.updated_at|date:"Y-m-d H:i" }}</td>
              <td>
                <a href="{% url 'voice:mega-prompt-edit' tpl.pk %}">Edit (→ new version)</a>
                <form method="post" action="{% url 'voice:mega-prompt-toggle' tpl.pk %}" style="display:inline">
                  {% csrf_token %}
                  <button type="submit">{% if tpl.is_active %}Deactivate{% else %}Activate{% endif %}</button>
                </form>
              </td>
            </tr>
          {% endif %}
        {% endfor %}
      </tbody>
    </table>
  </section>
{% endfor %}
{% endblock %}
```

(If `voice/base.html` doesn't exist, replace `extends` with bare HTML — check the existing templates first to follow the project's convention.)

- [ ] **Step 3: Wire URL**

Open `voice/urls.py`. Add an import for the new view (with other view imports) and append a URL pattern:

```python
from voice.views import MegaPromptListView

# ... existing urlpatterns ...

urlpatterns += [
    path("mega-prompts/", MegaPromptListView.as_view(), name="mega-prompt-list"),
]
```

(Add the two further routes — `mega-prompt-create`, `mega-prompt-edit`, `mega-prompt-toggle` — as placeholders so the template doesn't 500. Add stub views in Task 18-19. For now, define them with `path("mega-prompts/new/", MegaPromptListView.as_view(), name="mega-prompt-create")` etc. — placeholder pointing at the list so URLs resolve.)

- [ ] **Step 4: Smoke verify**

Run dev server: `python manage.py runserver 0.0.0.0:8007`
Visit `http://localhost:8007/voice/mega-prompts/` as a staff user.
Expected: page renders with three sections (Pre-call, Post-call, Lessons distill), each showing the seeded v1 row.
Stop server.

- [ ] **Step 5: Commit**

```bash
git add voice/views.py voice/urls.py voice/templates/voice/mega_prompt_list.html
git commit -m "Add mega-prompt list view + template (staff-only)"
```

---

### Task 18: Mega-prompt create/edit view (creates new version on save)

**Files:**
- Modify: `voice/forms.py`
- Modify: `voice/views.py`
- Modify: `voice/urls.py`
- Create: `voice/templates/voice/mega_prompt_form.html`

- [ ] **Step 1: Add the form**

Open `voice/forms.py`. Append:

```python
from django import forms

from voice.models import MegaPrompt


class MegaPromptForm(forms.ModelForm):
    class Meta:
        model = MegaPrompt
        fields = ("domain", "name", "meta_prompt")
        widgets = {
            "meta_prompt": forms.Textarea(attrs={"rows": 30, "spellcheck": "false"}),
        }
```

- [ ] **Step 2: Add Create + Update views**

In `voice/views.py` append:

```python
from django.contrib import messages
from django.db import transaction as db_transaction
from django.db.models import Max
from django.shortcuts import redirect
from django.urls import reverse_lazy
from django.views.generic import CreateView, UpdateView

from voice.forms import MegaPromptForm


class MegaPromptCreateView(_StaffRequiredMixin, CreateView):
    model = _MegaPromptModel
    form_class = MegaPromptForm
    template_name = "voice/mega_prompt_form.html"
    success_url = reverse_lazy("voice:mega-prompt-list")

    def get_initial(self):
        init = super().get_initial()
        if "domain" in self.request.GET:
            init["domain"] = self.request.GET["domain"]
        return init

    def form_valid(self, form):
        with db_transaction.atomic():
            domain = form.instance.domain
            max_v = (
                _MegaPromptModel.objects.select_for_update()
                .filter(domain=domain).aggregate(Max("version"))["version__max"]
            ) or 0
            form.instance.version = max_v + 1
            form.instance.created_by = self.request.user
            messages.success(self.request, f"{form.instance.get_domain_display()} v{form.instance.version} created (inactive). Toggle Activate to use.")
            return super().form_valid(form)


class MegaPromptUpdateView(_StaffRequiredMixin, UpdateView):
    """Edit-as-new-version. Never mutates the existing row in place."""

    model = _MegaPromptModel
    form_class = MegaPromptForm
    template_name = "voice/mega_prompt_form.html"
    success_url = reverse_lazy("voice:mega-prompt-list")

    def form_valid(self, form):
        original = self.get_object()
        if not form.has_changed():
            messages.info(self.request, "No changes detected.")
            return redirect(self.success_url)
        with db_transaction.atomic():
            max_v = (
                _MegaPromptModel.objects.select_for_update()
                .filter(domain=original.domain).aggregate(Max("version"))["version__max"]
            ) or 0
            new = _MegaPromptModel.objects.create(
                domain=original.domain,
                name=form.cleaned_data["name"],
                meta_prompt=form.cleaned_data["meta_prompt"],
                is_active=False,  # explicit toggle to activate
                version=max_v + 1,
                created_by=self.request.user,
            )
            messages.success(self.request, f"{new.get_domain_display()} v{new.version} created (inactive).")
            return redirect(self.success_url)
```

- [ ] **Step 3: Wire URLs (replace the Task 17 placeholders)**

In `voice/urls.py`:

```python
from voice.views import MegaPromptCreateView, MegaPromptUpdateView

# Replace the placeholder routes for mega-prompt-create / mega-prompt-edit
urlpatterns += [
    path("mega-prompts/new/", MegaPromptCreateView.as_view(), name="mega-prompt-create"),
    path("mega-prompts/<int:pk>/edit/", MegaPromptUpdateView.as_view(), name="mega-prompt-edit"),
]
```

- [ ] **Step 4: Create the form template**

Create `voice/templates/voice/mega_prompt_form.html`:

```html
{% extends "voice/base.html" %}
{% block content %}
<h1>{% if form.instance.pk %}Edit (creates new version){% else %}New mega prompt{% endif %}</h1>
<form method="post">
  {% csrf_token %}
  {{ form.as_p }}
  <p>
    <button type="submit" class="btn">Save as new version</button>
    <a href="{% url 'voice:mega-prompt-list' %}">Cancel</a>
  </p>
</form>
{% endblock %}
```

- [ ] **Step 5: Smoke verify in browser**

Run server. As staff:
- Visit `/voice/mega-prompts/`, click "+ New version" under Pre-call.
- Fill name `Test v?`, change one line in the meta_prompt text. Submit.
- Verify new row appears, marked inactive, with version one higher than the current max.
- Click "Edit (→ new version)" on the new row; change again; submit. Another row appears.

- [ ] **Step 6: Commit**

```bash
git add voice/forms.py voice/views.py voice/urls.py voice/templates/voice/mega_prompt_form.html
git commit -m "Add MegaPrompt create/edit (edit = new version, never in-place)"
```

---

### Task 19: Mega-prompt activate toggle (atomic) + auto-export on activate

**Files:**
- Modify: `voice/views.py`
- Modify: `voice/urls.py`

- [ ] **Step 1: Add the toggle view**

In `voice/views.py` append:

```python
from io import StringIO
from django.core.management import call_command
from django.shortcuts import get_object_or_404
from django.views import View

from voice.constants import LogLevel
from voice.services.logging import log_activity


class MegaPromptToggleActiveView(_StaffRequiredMixin, View):
    """POST /voice/mega-prompts/<pk>/toggle-active/

    Activating atomically deactivates any other active row in the same domain.
    After activation, auto-exports the active rows back to seed files (in-place
    rewrite of the .txt file for that domain) so the repo stays in sync.
    """

    def post(self, request, pk):
        with db_transaction.atomic():
            tpl = _MegaPromptModel.objects.select_for_update().get(pk=pk)
            if not tpl.is_active:
                _MegaPromptModel.objects.filter(
                    domain=tpl.domain, is_active=True
                ).exclude(pk=pk).update(is_active=False)
                tpl.is_active = True
                tpl.save(update_fields=["is_active", "updated_at"])
                log_activity(
                    user=request.user,
                    action=f"Activated MegaPrompt [{tpl.get_domain_display()}] v{tpl.version}",
                    details={"mega_prompt_id": tpl.pk, "domain": tpl.domain},
                )
                # Auto-export: rewrite the seed file for this domain
                buf = StringIO()
                call_command("export_mega_prompts", stdout=buf)
                messages.success(request, f"Activated v{tpl.version}; seed files updated.")
            else:
                tpl.is_active = False
                tpl.save(update_fields=["is_active", "updated_at"])
                log_activity(
                    user=request.user,
                    action=f"Deactivated MegaPrompt [{tpl.get_domain_display()}] v{tpl.version}",
                    details={"mega_prompt_id": tpl.pk, "domain": tpl.domain},
                    level=LogLevel.WARNING,
                )
                messages.warning(request, f"Deactivated v{tpl.version}. No active version remains for this domain!")
        return redirect("voice:mega-prompt-list")
```

- [ ] **Step 2: Wire the URL**

In `voice/urls.py`:

```python
from voice.views import MegaPromptToggleActiveView

urlpatterns += [
    path("mega-prompts/<int:pk>/toggle-active/", MegaPromptToggleActiveView.as_view(), name="mega-prompt-toggle"),
]
```

- [ ] **Step 3: Smoke verify**

Run dev server. As staff:
- Create a new PRE_CALL version via the form. Note its version number, e.g. v3.
- On the list page, click "Activate" on v3.
- Observe: v3 row now shows "✓ active"; the previous active row is no longer active.
- Open `voice/management/commands/seed_data/mega_prompts/pre_call.txt` and confirm its content matches v3.
- Click "Deactivate" on v3 → page reflects no active row + warning toast.
- Click "Activate" on v3 again to restore the green state.

- [ ] **Step 4: Commit**

```bash
git add voice/views.py voice/urls.py
git commit -m "Add mega-prompt activate toggle (atomic, auto-exports seed file)"
```

---

### Task 20: Visit page — lock icons + toggle endpoint

**Files:**
- Modify: `voice/views.py`
- Modify: `voice/urls.py`
- Modify: the existing visit detail template (find via `grep -r visit_detail voice/templates/`)

- [ ] **Step 1: Locate the visit detail template**

```bash
grep -rn "pre_call_prompt" voice/templates/ | head
```

Note the template file path. (Likely `voice/templates/voice/visit_detail.html`.)

- [ ] **Step 2: Add the lock toggle view**

In `voice/views.py` append:

```python
from voice.models import Visit


LOCK_FIELD_MAP = {
    "pre_prompt": "pre_call_prompt_locked",
    "pre_first": "pre_call_first_message_locked",
    "post_prompt": "post_call_prompt_locked",
    "post_first": "post_call_first_message_locked",
}


class VisitLockToggleView(_StaffRequiredMixin, View):
    """POST /voice/visits/<int:pk>/lock/<str:field>/

    `field` is one of pre_prompt / pre_first / post_prompt / post_first.
    Toggles the corresponding *_locked boolean on the Visit.
    """

    def post(self, request, pk, field):
        if field not in LOCK_FIELD_MAP:
            return redirect("voice:visit-detail", pk=pk)  # ignore malformed
        attr = LOCK_FIELD_MAP[field]
        visit = get_object_or_404(Visit, pk=pk)
        new_state = not getattr(visit, attr)
        setattr(visit, attr, new_state)
        visit.save(update_fields=[attr, "updated_at"])
        log_activity(
            user=request.user,
            action=f"{'Locked' if new_state else 'Unlocked'} {attr} on visit #{pk}",
            details={"visit_id": pk, "field": attr, "locked": new_state},
        )
        return redirect("voice:visit-detail", pk=pk)
```

- [ ] **Step 3: Wire URL**

In `voice/urls.py`:

```python
from voice.views import VisitLockToggleView

urlpatterns += [
    path("visits/<int:pk>/lock/<str:field>/", VisitLockToggleView.as_view(), name="visit-lock-toggle"),
]
```

(If `voice:visit-detail` doesn't exist under that name, find the visit-detail URL name via `grep "name=.visit" voice/urls.py` and adjust the redirect accordingly.)

- [ ] **Step 4: Add lock icons to the visit template**

In the visit detail template, for each of the four prompt fields, replace the existing field heading with a row that includes a lock-toggle form. Example for `pre_call_prompt`:

```html
<div class="prompt-field">
  <header>
    <h3>Pre-call prompt</h3>
    <form method="post" action="{% url 'voice:visit-lock-toggle' visit.pk 'pre_prompt' %}" style="display:inline">
      {% csrf_token %}
      <button type="submit" class="lock-btn">
        {% if visit.pre_call_prompt_locked %}🔒 locked{% else %}🔓 unlocked{% endif %}
      </button>
    </form>
  </header>
  <pre>{{ visit.pre_call_prompt|default:"(not yet generated)" }}</pre>
</div>
```

Repeat for `pre_first` / `post_prompt` / `post_first` (replacing field name + heading + locked flag accordingly).

- [ ] **Step 5: Write local-only test for lock toggle**

Create `voice/_tests_local/test_visit_locks.py`:

```python
"""Local-only tests for the visit lock toggle."""

from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from voice.models import Client, User, Visit


class VisitLockToggleTests(TestCase):
    def setUp(self):
        self.staff = User.objects.create_user(username="s", password="x", is_staff=True)
        self.agent = User.objects.create_user(username="a", password="x")
        self.client_obj = Client.objects.create(name="ACME")
        self.visit = Visit.objects.create(
            agent=self.agent, client=self.client_obj, title="V",
            start_time=timezone.now(), end_time=timezone.now(),
        )

    def test_toggle_flips_flag(self):
        self.client.force_login(self.staff)
        url = reverse("voice:visit-lock-toggle", args=[self.visit.pk, "pre_prompt"])
        r = self.client.post(url)
        self.assertEqual(r.status_code, 302)
        self.visit.refresh_from_db()
        self.assertTrue(self.visit.pre_call_prompt_locked)
        r = self.client.post(url)
        self.visit.refresh_from_db()
        self.assertFalse(self.visit.pre_call_prompt_locked)

    def test_non_staff_403(self):
        self.client.force_login(self.agent)
        url = reverse("voice:visit-lock-toggle", args=[self.visit.pk, "pre_prompt"])
        r = self.client.post(url)
        self.assertEqual(r.status_code, 403)
```

Run: `python manage.py test voice._tests_local.test_visit_locks -v 2`
Expected: 2 tests pass.

- [ ] **Step 6: Smoke verify in browser**

Run dev server. As staff, open a visit detail page. Click the lock button next to "Pre-call prompt"; observe the badge toggles and the page reloads.

- [ ] **Step 7: Commit**

```bash
git add voice/views.py voice/urls.py voice/templates/voice/visit_detail.html
git commit -m "Add per-field lock icons + toggle endpoint on visit page"
```

---

### Task 21: Regenerate buttons + last-run panel + auto-lock on manual edit

**Files:**
- Modify: `voice/views.py`
- Modify: `voice/urls.py`
- Modify: `voice/forms.py`
- Modify: visit detail template

- [ ] **Step 1: Add regenerate views**

In `voice/views.py` append:

```python
from voice.models import GenerationRun
from voice.services.assembler import assemble_pre_call, assemble_post_call


class VisitRegenerateView(_StaffRequiredMixin, View):
    """POST /voice/visits/<int:pk>/regenerate/<str:domain>/

    `domain` is "pre" or "post".
    """

    def post(self, request, pk, domain):
        visit = get_object_or_404(Visit, pk=pk)
        if domain == "pre":
            run = assemble_pre_call(visit, triggered_by=GenerationRun.TriggeredBy.MANUAL, user=request.user)
        elif domain == "post":
            run = assemble_post_call(visit, triggered_by=GenerationRun.TriggeredBy.MANUAL, user=request.user)
        else:
            return redirect("voice:visit-detail", pk=pk)
        if run.success:
            messages.success(request, f"{domain.upper()} prompt regenerated. Tokens: in={run.input_tokens} out={run.output_tokens}.")
        else:
            messages.error(request, f"{domain.upper()} regeneration failed: {run.error}")
        return redirect("voice:visit-detail", pk=pk)
```

- [ ] **Step 2: Wire URL**

In `voice/urls.py`:

```python
from voice.views import VisitRegenerateView

urlpatterns += [
    path("visits/<int:pk>/regenerate/<str:domain>/", VisitRegenerateView.as_view(), name="visit-regenerate"),
]
```

- [ ] **Step 3: Add the buttons + last-run panel to the visit template**

In the visit detail template, near the prompt fields, add:

```html
<section class="assembler-actions">
  <form method="post" action="{% url 'voice:visit-regenerate' visit.pk 'pre' %}" style="display:inline">
    {% csrf_token %}
    <button type="submit">Regenerate pre-call</button>
  </form>
  <form method="post" action="{% url 'voice:visit-regenerate' visit.pk 'post' %}" style="display:inline">
    {% csrf_token %}
    <button type="submit">Regenerate post-call</button>
  </form>
</section>

<section class="last-runs">
  <h3>Last assembler runs</h3>
  {% for run in visit.generation_runs.all|slice:":4" %}
    <div class="run">
      <strong>{{ run.get_domain_display }}</strong>
      <span>{{ run.created_at|date:"Y-m-d H:i" }}</span>
      <span>{{ run.triggered_by }}</span>
      <span>{% if run.success %}✓{% else %}✗ {{ run.error|truncatechars:80 }}{% endif %}</span>
      <span>tokens in/out: {{ run.input_tokens }}/{{ run.output_tokens }}</span>
      <a href="{% url 'voice:generation-run-detail' run.pk %}">details</a>
    </div>
  {% empty %}
    <p>No runs yet.</p>
  {% endfor %}
</section>
```

(Note: `voice:generation-run-detail` URL is added in Task 23. Leave the link broken for now or comment it out until then.)

- [ ] **Step 4: Auto-lock on manual edit of any of the four prompt fields**

Open `voice/forms.py`. Locate the form used on the Visit edit page (search for `class VisitForm`). If none exists, look in `voice/views.py` for the visit UpdateView — Django may use a model form generated from `fields = [...]`.

In whichever Form-or-View handles the manual edit, override `form_valid` (or `save`) to set `*_locked = True` for any field that was changed:

```python
LOCK_PAIRS = (
    ("pre_call_prompt", "pre_call_prompt_locked"),
    ("pre_call_first_message", "pre_call_first_message_locked"),
    ("post_call_prompt", "post_call_prompt_locked"),
    ("post_call_first_message", "post_call_first_message_locked"),
)


# Inside the relevant view/form save logic, after detecting which fields changed
# (form.changed_data gives the list of changed bound field names):
for field_name, lock_name in LOCK_PAIRS:
    if field_name in form.changed_data:
        setattr(instance, lock_name, True)
```

Add this snippet wherever Visit is saved from a manager-facing form. Critically: the assembler does NOT use this form when writing, so its writes won't flip the lock.

- [ ] **Step 5: Local test for auto-lock behavior**

Create `voice/_tests_local/test_visit_autolock.py`:

```python
"""Local-only tests for auto-lock on manual edit."""

from django.test import TestCase
from django.urls import reverse
from django.utils import timezone

from voice.models import Client, User, Visit


class AutoLockTests(TestCase):
    def setUp(self):
        self.staff = User.objects.create_user(username="s", password="x", is_staff=True)
        self.agent = User.objects.create_user(username="a", password="x")
        self.client_obj = Client.objects.create(name="ACME")
        self.visit = Visit.objects.create(
            agent=self.agent, client=self.client_obj, title="V",
            start_time=timezone.now(), end_time=timezone.now(),
            pre_call_prompt="original",
        )
        self.client.force_login(self.staff)

    def test_editing_pre_call_prompt_locks_it(self):
        # Adjust this to the actual visit-edit URL name in your project.
        from django.urls import NoReverseMatch
        try:
            url = reverse("voice:visit-edit", args=[self.visit.pk])
        except NoReverseMatch:
            self.skipTest("voice:visit-edit url name not present; adjust to your project's name")
        r = self.client.post(url, data={
            "pre_call_prompt": "edited by manager",
            # include other required fields here matching your form...
        })
        self.assertIn(r.status_code, (200, 302))
        self.visit.refresh_from_db()
        self.assertEqual(self.visit.pre_call_prompt, "edited by manager")
        self.assertTrue(self.visit.pre_call_prompt_locked)
```

Run: `python manage.py test voice._tests_local.test_visit_autolock -v 2`
(May skip if the URL name differs — fix accordingly.)

- [ ] **Step 6: Smoke verify in browser**

Run server. On a visit detail page:
- Click "Regenerate pre-call". Wait. Page reloads with the new pre-call body. The "Last runs" section shows the new run.
- Manually edit the pre-call body (via the existing edit form) and save. Confirm the lock icon now shows 🔒.
- Click "Regenerate pre-call" again. The body should NOT change (locked). The "Last runs" section still records the run, and the manager sees a success message confirming generation ran (the first_message — if not locked — should change).

- [ ] **Step 7: Commit**

```bash
git add voice/views.py voice/urls.py voice/forms.py voice/templates/voice/visit_detail.html
git commit -m "Add regenerate buttons + last-run panel + auto-lock on manual edit"
```

---

### Task 22: Client lessons-learned editor

**Files:**
- Modify: `voice/views.py`
- Modify: `voice/urls.py`
- Modify: client detail template (find via grep)

- [ ] **Step 1: Find the client detail template**

```bash
grep -rn "client_detail\|client.name" voice/templates/ | head
```

Note the path.

- [ ] **Step 2: Add a small form view**

In `voice/views.py` append:

```python
from voice.models import Client


class ClientLessonsLearnedUpdateView(_StaffRequiredMixin, View):
    """POST /voice/clients/<pk>/lessons-learned/ — update Client.lessons_learned."""

    def post(self, request, pk):
        client = get_object_or_404(Client, pk=pk)
        new_text = request.POST.get("lessons_learned", "").strip()
        old_text = client.lessons_learned or ""
        if new_text != old_text:
            client.lessons_learned = new_text
            client.save(update_fields=["lessons_learned", "updated_at"])
            log_activity(
                user=request.user,
                action=f"Manually updated lessons_learned for {client.name}",
                details={"client_id": client.pk, "old_len": len(old_text), "new_len": len(new_text)},
            )
            messages.success(request, "Lessons learned updated.")
        return redirect("voice:client-detail", pk=pk)
```

- [ ] **Step 3: Wire URL**

In `voice/urls.py`:

```python
from voice.views import ClientLessonsLearnedUpdateView

urlpatterns += [
    path("clients/<int:pk>/lessons-learned/", ClientLessonsLearnedUpdateView.as_view(), name="client-lessons-update"),
]
```

(Adjust the `client-detail` name in the redirect to match your project.)

- [ ] **Step 4: Add the editor block to the client template**

Append (or insert near other notes/summary blocks):

```html
<section class="lessons-learned">
  <h3>Lessons learned (closed-loop memory)</h3>
  <p class="hint">Distilled from prior calls. Edited here is preserved by the next distill.</p>
  <form method="post" action="{% url 'voice:client-lessons-update' client.pk %}">
    {% csrf_token %}
    <textarea name="lessons_learned" rows="10" style="width:100%">{{ client.lessons_learned }}</textarea>
    <button type="submit">Save</button>
  </form>
</section>
```

- [ ] **Step 5: Smoke verify**

Run server, visit a client detail page as staff, edit + save the lessons_learned. Reload. Confirm content persists.

- [ ] **Step 6: Commit**

```bash
git add voice/views.py voice/urls.py voice/templates/voice/client_detail.html
git commit -m "Add Client.lessons_learned editor (staff-only)"
```

---

### Task 23: GenerationRun list + detail views

**Files:**
- Modify: `voice/views.py`
- Modify: `voice/urls.py`
- Create: `voice/templates/voice/generation_run_list.html`
- Create: `voice/templates/voice/generation_run_detail.html`

- [ ] **Step 1: Add views**

In `voice/views.py` append:

```python
from django.views.generic import DetailView


class GenerationRunListView(_StaffRequiredMixin, ListView):
    model = GenerationRun
    template_name = "voice/generation_run_list.html"
    context_object_name = "runs"
    paginate_by = 50

    def get_queryset(self):
        qs = GenerationRun.objects.select_related("visit", "client", "mega_prompt").order_by("-created_at")
        domain = self.request.GET.get("domain")
        if domain:
            qs = qs.filter(domain=domain)
        success = self.request.GET.get("success")
        if success == "true":
            qs = qs.filter(success=True)
        elif success == "false":
            qs = qs.filter(success=False)
        return qs


class GenerationRunDetailView(_StaffRequiredMixin, DetailView):
    model = GenerationRun
    template_name = "voice/generation_run_detail.html"
    context_object_name = "run"
```

- [ ] **Step 2: Wire URLs**

In `voice/urls.py`:

```python
from voice.views import GenerationRunDetailView, GenerationRunListView

urlpatterns += [
    path("generation-runs/", GenerationRunListView.as_view(), name="generation-run-list"),
    path("generation-runs/<int:pk>/", GenerationRunDetailView.as_view(), name="generation-run-detail"),
]
```

- [ ] **Step 3: Create the list template**

`voice/templates/voice/generation_run_list.html`:

```html
{% extends "voice/base.html" %}
{% block content %}
<h1>Generation runs</h1>
<form method="get" class="filters">
  <select name="domain">
    <option value="">All domains</option>
    <option value="PRE_CALL"{% if request.GET.domain == 'PRE_CALL' %} selected{% endif %}>Pre-call</option>
    <option value="POST_CALL"{% if request.GET.domain == 'POST_CALL' %} selected{% endif %}>Post-call</option>
    <option value="LESSONS_DISTILL"{% if request.GET.domain == 'LESSONS_DISTILL' %} selected{% endif %}>Lessons distill</option>
  </select>
  <select name="success">
    <option value="">Any outcome</option>
    <option value="true"{% if request.GET.success == 'true' %} selected{% endif %}>Success only</option>
    <option value="false"{% if request.GET.success == 'false' %} selected{% endif %}>Failures only</option>
  </select>
  <button type="submit">Filter</button>
</form>
<table class="data-table">
  <thead><tr><th>When</th><th>Domain</th><th>Target</th><th>Trigger</th><th>OK?</th><th>Tokens (in/out)</th><th></th></tr></thead>
  <tbody>
    {% for run in runs %}
      <tr>
        <td>{{ run.created_at|date:"Y-m-d H:i" }}</td>
        <td>{{ run.get_domain_display }}</td>
        <td>{% if run.visit %}Visit #{{ run.visit_id }}{% elif run.client %}Client #{{ run.client_id }}{% endif %}</td>
        <td>{{ run.get_triggered_by_display }}</td>
        <td>{% if run.success %}✓{% else %}✗{% endif %}</td>
        <td>{{ run.input_tokens }}/{{ run.output_tokens }}</td>
        <td><a href="{% url 'voice:generation-run-detail' run.pk %}">details</a></td>
      </tr>
    {% endfor %}
  </tbody>
</table>
{% if is_paginated %}
  <nav class="pagination">
    {% if page_obj.has_previous %}<a href="?page={{ page_obj.previous_page_number }}">prev</a>{% endif %}
    page {{ page_obj.number }} of {{ paginator.num_pages }}
    {% if page_obj.has_next %}<a href="?page={{ page_obj.next_page_number }}">next</a>{% endif %}
  </nav>
{% endif %}
{% endblock %}
```

- [ ] **Step 4: Create the detail template**

`voice/templates/voice/generation_run_detail.html`:

```html
{% extends "voice/base.html" %}
{% block content %}
<h1>Run #{{ run.pk }} — {{ run.get_domain_display }}</h1>
<p>
  When: {{ run.created_at }} ·
  Trigger: {{ run.get_triggered_by_display }} ·
  Tokens: {{ run.input_tokens }} in / {{ run.output_tokens }} out ·
  {% if run.success %}<span class="ok">SUCCESS</span>{% else %}<span class="fail">FAIL — {{ run.error }}</span>{% endif %}
</p>
<p>MegaPrompt used: <a href="{% url 'voice:mega-prompt-list' %}">{{ run.mega_prompt }}</a></p>

<h2>Context bundle</h2>
<pre>{{ run.context_bundle|pprint }}</pre>

<h2>Claude request (rendered)</h2>
<pre>{{ run.claude_request }}</pre>

<h2>Claude response (raw)</h2>
<pre>{{ run.claude_response }}</pre>

<h2>Parsed outputs</h2>
<pre>{{ run.parsed_outputs|pprint }}</pre>
{% endblock %}
```

- [ ] **Step 5: Smoke verify**

Run server. After regenerating a prompt (Task 21), visit `/voice/generation-runs/` and confirm the row appears. Click "details"; confirm context bundle + request + response render.

- [ ] **Step 6: Commit**

```bash
git add voice/views.py voice/urls.py voice/templates/voice/generation_run_list.html voice/templates/voice/generation_run_detail.html
git commit -m "Add GenerationRun list + detail views (staff-only, filterable)"
```

---

### Task 24: Migrate existing `GlobalSettings.pre/post_call_meta_prompt` content into MegaPrompt

**Files:**
- Create empty data migration

- [ ] **Step 1: Generate the empty migration**

```bash
python manage.py makemigrations voice --empty --name migrate_globalsettings_to_megaprompt
```

Expected: `voice/migrations/0024_migrate_globalsettings_to_megaprompt.py` created.

- [ ] **Step 2: Fill in the data migration**

Open the new migration and replace `operations = []` with:

```python
def migrate_meta_prompts(apps, schema_editor):
    GlobalSettings = apps.get_model("voice", "GlobalSettings")
    MegaPrompt = apps.get_model("voice", "MegaPrompt")

    gs = GlobalSettings.objects.first()
    if gs is None:
        return

    pairs = (
        ("PRE_CALL", "pre_call_meta_prompt"),
        ("POST_CALL", "post_call_meta_prompt"),
    )
    for domain, field in pairs:
        existing_active = MegaPrompt.objects.filter(domain=domain, is_active=True).first()
        if existing_active:
            continue
        value = (getattr(gs, field, None) or "").strip()
        if not value:
            # The seed file already provides a starter; leave the row to be created by seed_mega_prompts.
            continue
        MegaPrompt.objects.create(
            domain=domain,
            name=f"Migrated from GlobalSettings.{field}",
            meta_prompt=value,
            is_active=True,
            version=1,
        )


def noop_reverse(apps, schema_editor):
    pass


operations = [
    migrations.RunPython(migrate_meta_prompts, noop_reverse),
]
```

- [ ] **Step 3: Apply**

```bash
python manage.py migrate
```

- [ ] **Step 4: Smoke verify**

If the GlobalSettings text fields were populated before this migration, expect to see PRE_CALL and POST_CALL active MegaPrompt rows whose `meta_prompt` matches the legacy text. Inspect via `/voice/mega-prompts/`.

If they were empty, the seeded rows from `seed_mega_prompts` remain active and the migration was a no-op for those domains.

- [ ] **Step 5: Commit**

```bash
git add voice/migrations/0024_*.py
git commit -m "Migrate GlobalSettings meta-prompts into MegaPrompt rows"
```

---

### Task 25: Remove the deprecated `GlobalSettings.pre/post_call_meta_prompt` fields

**Files:**
- Modify: `voice/models.py`
- Migration auto-generated

- [ ] **Step 1: Remove the two TextField definitions from `GlobalSettings`**

In `voice/models.py`, locate the `GlobalSettings` class (around line 484). Delete the lines defining `pre_call_meta_prompt` and `post_call_meta_prompt` (lines ~496-505).

- [ ] **Step 2: Generate + apply the migration**

```bash
python manage.py makemigrations voice
python manage.py migrate
```

Expected: a migration named like `0025_remove_globalsettings_pre_call_meta_prompt_and_more.py` is created and applies cleanly.

- [ ] **Step 3: Smoke verify**

```bash
python manage.py check
python manage.py shell -c "from voice.models import GlobalSettings; gs = GlobalSettings.load(); print(hasattr(gs, 'pre_call_meta_prompt'))"
```

Expected: `0 issues` then `False`.

- [ ] **Step 4: Search for stale references**

```bash
grep -rn "pre_call_meta_prompt\|post_call_meta_prompt" voice/ --include="*.py" | grep -v migrations
```

Expected: no hits. If any exist (templates, views, admin), remove them.

- [ ] **Step 5: Commit**

```bash
git add voice/models.py voice/migrations/0025_*.py
git commit -m "Drop GlobalSettings.pre/post_call_meta_prompt (moved to MegaPrompt)"
```

---

### Task 26: Delete `voice/services/prompt_builder.py` and finalise `__init__.py`

**Files:**
- Delete: `voice/services/prompt_builder.py`
- Modify: `voice/services/__init__.py` if any stale references remain

- [ ] **Step 1: Search for remaining imports of prompt_builder**

```bash
grep -rn "from voice.services.prompt_builder\|services.prompt_builder\|import prompt_builder" --include="*.py" .
```

Expected: only the file itself shows up. If any caller still imports it, switch them to `voice.services.assembler` per Task 15/16 patterns.

- [ ] **Step 2: Delete the file**

```bash
git rm voice/services/prompt_builder.py
```

- [ ] **Step 3: Verify Django still boots**

```bash
python manage.py check
python manage.py runserver 0.0.0.0:8007 &
sleep 2
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8007/admin/
kill %1
```

Expected: `0 issues`, then `302` (or `200` if logged in via session cookie).

- [ ] **Step 4: Commit**

```bash
git commit -m "Remove deprecated voice/services/prompt_builder.py (replaced by assembler)"
```

---

### Task 27: End-of-meeting webhook — chain assemble_post_call + distill_lessons

**Files:**
- Modify: `voice/webhook_views.py`

- [ ] **Step 1: Locate the post-call success handler**

```bash
grep -n "post_call_summary\|generate_voice_prompt\|process_visit_post_call" voice/webhook_views.py | head
```

Note the area where the meeting transcript is finalised after an ElevenLabs post-call webhook arrives.

- [ ] **Step 2: After the existing post-call summarisation, chain the assembler + distiller**

The existing flow (in `tasks.py:process_visit_post_call_completion`) is already triggered. Task 16 wired the LESSONS_DISTILL chain there. For webhook-driven retrigger we want to ensure that on receiving the transcript itself, we ALSO rerun `assemble_post_call(visit, transcript=...)` so the post-call prompt now contains the transcript (for cases where the post-call is regenerated AFTER the meeting transcript exists — e.g., remixing once a transcript lands).

Add near the place where the transcript is persisted on the Visit (search for `visit.post_call_summary =` or equivalent):

```python
# If the transcript landed AFTER the post-call prompt was generated, regenerate it
# so the prompt incorporates the actual transcript for any subsequent dial.
try:
    from voice.models import GenerationRun
    from voice.services.assembler import assemble_post_call

    assemble_post_call(
        visit,
        transcript=transcript_text or "",
        triggered_by=GenerationRun.TriggeredBy.END_OF_MEETING,
    )
except Exception:
    logger.exception("End-of-meeting POST_CALL regen failed for visit=%s", visit.id)
```

(Adjust variable names to match what the webhook actually has in scope — `transcript_text`, `visit`, etc.)

- [ ] **Step 3: Smoke verify**

This is hard to test in isolation without a real ElevenLabs webhook. Two options:
- Add an in-shell trigger: `python manage.py shell -c "from voice.models import Visit; from voice.services.assembler import assemble_post_call; v = Visit.objects.last(); print(assemble_post_call(v, transcript='Customer was interested.').success)"`
- Or wait until the next live demo loops one through.

Expected: `True` (assuming LLM is configured and an active POST_CALL MegaPrompt exists).

- [ ] **Step 4: Commit**

```bash
git add voice/webhook_views.py
git commit -m "Wire end-of-meeting webhook to regen post-call prompt with fresh transcript"
```

---

### Task 28: Final smoke test + dumpdata backup snapshot

**Files:**
- Modify: `backups/` (already gitignored — just produce a fresh dump)

- [ ] **Step 1: Run all checks**

```bash
python manage.py check
python manage.py migrate --plan | tail -5
```

Expected: `0 issues`; no unapplied migrations.

- [ ] **Step 2: Manual end-to-end smoke**

Run dev server. Execute this checklist as a staff user:

1. `/voice/mega-prompts/` — three domains, each with at least one active version.
2. Create a new PRE_CALL version, activate it, observe the seed file `voice/management/commands/seed_data/mega_prompts/pre_call.txt` updated on disk.
3. Open a Visit. Click "Regenerate pre-call". Watch the prompt fields populate. Check `/voice/generation-runs/` — new row.
4. Manually edit the pre-call body, save. Reload visit page; lock icon is now 🔒. Click "Regenerate pre-call" again. Body should NOT change; first_message MAY change (depending on its own lock).
5. Open a Client page. Edit lessons_learned. Save. Confirm persists.
6. Stop the server.

- [ ] **Step 3: Take a backup snapshot**

```bash
mkdir -p backups
python manage.py dumpdata \
  voice.MegaPrompt voice.Scenario voice.GenerationRun voice.Client voice.Visit voice.GlobalSettings \
  --indent 2 > backups/auto-prompt-assembler-snapshot-$(date +%Y%m%d-%H%M%S).json
```

Expected: file produced. (Not committed — `backups/` is local-only or gitignored per project convention.)

- [ ] **Step 4: Final commit + branch push instructions**

If anything was modified during the smoke test (e.g., minor template tweaks), commit it:

```bash
git status --short
# If there are changes:
git add -p   # review before staging
git commit -m "Final smoke-test polish for Auto Prompt Assembler"
```

Push the branch when ready:

```bash
git push -u origin claude/auto-prompt-assembler
```

Then open a PR against `main` per the project's branch workflow (see [feedback_branch_workflow memory](../../../../../.claude/projects/-Users-alex-Code-proj-salesassistant/memory/feedback_branch_workflow.md)).

---

## Self-review checklist (for the executing engineer)

Before declaring the feature done, walk through:

- [ ] All 28 tasks completed.
- [ ] `python manage.py check` produces `0 issues`.
- [ ] `python manage.py migrate --plan` shows no unapplied migrations.
- [ ] `grep -rn "prompt_builder" voice/ --include="*.py"` returns nothing (file fully removed and no stale imports).
- [ ] `grep -rn "pre_call_meta_prompt\|post_call_meta_prompt" voice/ --include="*.py" | grep -v migrations` returns nothing.
- [ ] All three MegaPrompt domains have an active row.
- [ ] Editing + activating a MegaPrompt updates the corresponding seed file on disk.
- [ ] Manual prompt edit on a Visit auto-locks that field; assembler skips it on next regen.
- [ ] `voice/_tests_local/` is NOT in `git status` (gitignored).
- [ ] Backup dumpdata snapshot exists under `backups/`.
