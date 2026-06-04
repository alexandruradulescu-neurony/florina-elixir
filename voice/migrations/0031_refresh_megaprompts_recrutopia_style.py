# Generated for the Recrutopia-style mega-prompt refresh.
#
# Migration 0025 only seeds a MegaPrompt for a domain when no active row exists.
# That's the right behavior for fresh installs, but it means an update to a
# seed file does NOT propagate to environments that already have an active row.
#
# This migration ports the seed-file content as a NEW active version for
# PRE_CALL and POST_CALL, deactivating the previous active row in the same
# transaction. Mirrors the `seed_mega_prompts --force` command logic, but
# scoped to PRE_CALL and POST_CALL only (LESSONS_DISTILL is untouched).

from pathlib import Path

from django.db import migrations
from django.db.models import Max

SEED_DIR = (
    Path(__file__).resolve().parent.parent
    / "management"
    / "commands"
    / "seed_data"
    / "mega_prompts"
)

DOMAINS_TO_REFRESH = {
    "PRE_CALL": "pre_call.txt",
    "POST_CALL": "post_call.txt",
}


def refresh_megaprompts(apps, schema_editor):
    """Create a new active MegaPrompt version per domain from the current seed file.

    If a domain has no active row yet (fresh install where 0025 didn't run for
    some reason), this still seeds it. Idempotency: re-running this migration
    by hand would create yet another version — but Django won't re-run a
    migration that's already applied, so in practice this runs exactly once
    per deploy that picks up the new code.
    """
    MegaPrompt = apps.get_model("voice", "MegaPrompt")

    for domain, filename in DOMAINS_TO_REFRESH.items():
        seed_path = SEED_DIR / filename
        if not seed_path.exists():
            raise FileNotFoundError(
                f"MegaPrompt seed file missing for domain {domain}: {seed_path}. "
                f"This file must exist for migration 0031 to refresh the active version."
            )

        content = seed_path.read_text(encoding="utf-8")
        if not content.strip():
            raise ValueError(
                f"MegaPrompt seed file for domain {domain} is empty: {seed_path}. "
                f"An empty meta-prompt would render the assembler non-functional."
            )

        existing_active = MegaPrompt.objects.filter(domain=domain, is_active=True).first()
        if existing_active and existing_active.meta_prompt == content:
            # No-op: the active row already matches the seed content. Skip so
            # we don't churn version numbers on a re-deploy.
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
            name=f"Seeded v{new_version} (Recrutopia-style refresh)",
            meta_prompt=content,
            is_active=True,
            version=new_version,
        )


def noop_reverse(apps, schema_editor):
    """Reverse is intentionally a no-op.

    Rolling back this migration would NOT restore the previous active version
    automatically — we'd need to know which one was previously active. The
    deactivated row is still in the table; an operator can flip the active
    flag back manually if needed via the admin UI.
    """


class Migration(migrations.Migration):
    dependencies = [
        ("voice", "0030_callattempt_retry_count"),
    ]

    operations = [
        migrations.RunPython(refresh_megaprompts, noop_reverse),
    ]
