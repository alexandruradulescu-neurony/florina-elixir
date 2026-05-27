# Settings Screen — Implementation Spec (Minimum)

**Date:** 2026-05-26
**Status:** Approved
**Builds on:** branch `calendar-screen`

## Goal
Restyle the existing global settings page to use the form-page chrome already shipped (`.form-layout`, `.form-card`, `.form-fieldset`, `.form-row`, `.form-sidebar`). No design package reference exists — we extrapolate from the established form pattern (agent_form, methodology_form).

## Locked decisions
- Scope = restyle only. No new fields, no section reorganization, no view/model/form changes.
- Same form contract: POST to `voice:global_settings`, CSRF token, preserve existing field names.

## File layout
- Modify: `voice/templates/voice/manager/settings.html` (full rewrite, ~140 lines)
- Don't touch: `GlobalSettingsView`, `GlobalSettings` model, `GlobalSettingsForm`, screens.css

## Template structure
- `{% block header_utility %}`: breadcrumb (single "Settings" crumb)
- `{% block display_title %}Settings{% endblock %}`
- `{% block display_subtitle %}Call timing, defaults, and AI meta-prompts{% endblock %}`
- `{% block content %}`: `<form method="post" class="form-layout">` with:
  - `.form-card` containing 4 `.form-fieldset` blocks:
    1. **Call timing** — 3-column grid of `.form-row` blocks for pre/post/retry minute inputs. Each row has an `<input type="number">` and inline "min" suffix via inline span. Helptext under each.
    2. **Defaults** — `default_methodology` `<select>` with "None" option + iteration over `form.fields.default_methodology.queryset`.
    3. **Pre-call meta-prompt** — `<textarea name="pre_call_meta_prompt" style="min-height:200px;font-family:monospace;font-size:12px;">`. Helptext.
    4. **Post-call meta-prompt** — same pattern.
  - `.form-sidebar` with:
    - `.card` containing `.form-actions` (Save primary button, full-width)
    - `.card` with `<h3>How settings apply</h3>` + 3 bullet-style rows using `.status-list` (each `<li>` with a `.dot.on`)
- Non-field errors rendered in `.toast.toast-error` above the form (same pattern as other forms).

## Verification
- `python manage.py check` passes.
- Visit `/manager/settings/` — page renders with new chrome, 4 fieldsets visible, sidebar sticky.
- Submit form with valid values — saves and redirects (existing view behavior).
- Submit with invalid values — `.field-error` displays inline under offenders.

## Out of scope
- Any new settings fields
- Section reorganization
- View / model / form changes
- Drop methodology select to a custom-styled dropdown

## Rollout
Stay uncommitted, branch + commit on `settings-screen` off `calendar-screen`.
