# Ship the rewritten PRE_CALL meta-prompt (PR #30: objective-led, methodology
# used for its real technique, balanced readiness check, rehearsal as the core)
# to the database on deploy.
#
# WHY THIS MIGRATION EXISTS: the app reads meta-prompts from the database
# (the active MegaPrompt row), not from the seed file. PR #30 changed
# `seed_data/mega_prompts/pre_call.txt` but shipped no migration, so the live
# active PRE_CALL version never changed. This mirrors migrations 0031/0032 —
# read the current seed file, retire the active row, create a new active
# version — so prod picks up the new recipe on auto-deploy without anyone
# running `python manage.py seed_mega_prompts --force` by hand.
#
# Scoped to PRE_CALL only: PR #30 did not change post_call.txt or
# lessons_distill.txt, so their active versions are left untouched.
#
# Idempotent: if the active PRE_CALL row already matches the seed file (e.g. a
# re-deploy, or someone already activated this content via the Mega Prompts
# UI), this no-ops without churning version numbers.

from pathlib import Path

from django.db import migrations
from django.db.models import Max

SEED_PATH = (
    Path(__file__).resolve().parent.parent
    / "management"
    / "commands"
    / "seed_data"
    / "mega_prompts"
    / "pre_call.txt"
)


def refresh_pre_call(apps, schema_editor):
    """Create a new active PRE_CALL MegaPrompt version from the seed file."""
    MegaPrompt = apps.get_model("voice", "MegaPrompt")

    if not SEED_PATH.exists():
        raise FileNotFoundError(
            f"PRE_CALL seed file missing: {SEED_PATH}. "
            f"It must exist for migration 0037 to refresh the active version."
        )
    content = SEED_PATH.read_text(encoding="utf-8")
    if not content.strip():
        raise ValueError(
            f"PRE_CALL seed file is empty: {SEED_PATH}. "
            f"An empty meta-prompt would render the assembler non-functional."
        )

    existing_active = MegaPrompt.objects.filter(domain="PRE_CALL", is_active=True).first()
    if existing_active and existing_active.meta_prompt == content:
        # Active row already matches the seed — nothing to do.
        return

    max_v = (
        MegaPrompt.objects.filter(domain="PRE_CALL").aggregate(Max("version"))["version__max"] or 0
    )
    new_version = max_v + 1

    if existing_active:
        existing_active.is_active = False
        existing_active.save(update_fields=["is_active", "updated_at"])

    MegaPrompt.objects.create(
        domain="PRE_CALL",
        name=f"Seeded v{new_version} (objective-led rewrite)",
        meta_prompt=content,
        is_active=True,
        version=new_version,
    )


def noop_reverse(apps, schema_editor):
    """Reverse is a no-op — the previous active row is still in the table and
    can be re-activated from the Mega Prompts UI if a rollback is needed.
    """


class Migration(migrations.Migration):
    dependencies = [
        ("voice", "0036_drop_meeting"),
    ]

    operations = [
        migrations.RunPython(refresh_pre_call, noop_reverse),
    ]
