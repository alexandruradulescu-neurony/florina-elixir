# Generated to refresh the active PRE_CALL/POST_CALL MegaPrompt rows after the
# hotfix landed (PR #16). Migration 0031 (PR #15) created active v2 rows from
# the original Recrutopia-style seeds, but those seeds had two latent bugs that
# made `assemble_pre_call` fail with 500 on Regenerate:
#
#   1. Mixed Romanian quotes („X") that broke JSON parsing.
#   2. Misleading "placeholderi literali (cu acolade)" wording that caused
#      Claude to wrap actual values in curly braces (`{Vlad}`).
#
# PR #16 fixed the seed files in place (asterisk citations, clearer placeholder
# guidance) and the assembler defenses (backtick-aware render, quote repair).
# This migration mirrors 0031 — read the now-corrected seed file, deactivate
# the current active row, create a new active version — so prod picks up the
# fixed content on auto-deploy without anyone running
# `python manage.py seed_mega_prompts --force` by hand.

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

    Idempotent: if the active row already matches the seed content (a
    re-deploy where the file hasn't changed), this no-ops without churning
    version numbers. The shape mirrors the `seed_mega_prompts --force` command,
    scoped to PRE_CALL and POST_CALL only (LESSONS_DISTILL is untouched).
    """
    MegaPrompt = apps.get_model("voice", "MegaPrompt")

    for domain, filename in DOMAINS_TO_REFRESH.items():
        seed_path = SEED_DIR / filename
        if not seed_path.exists():
            raise FileNotFoundError(
                f"MegaPrompt seed file missing for domain {domain}: {seed_path}. "
                f"This file must exist for migration 0032 to refresh the active version."
            )

        content = seed_path.read_text(encoding="utf-8")
        if not content.strip():
            raise ValueError(
                f"MegaPrompt seed file for domain {domain} is empty: {seed_path}. "
                f"An empty meta-prompt would render the assembler non-functional."
            )

        existing_active = MegaPrompt.objects.filter(domain=domain, is_active=True).first()
        if existing_active and existing_active.meta_prompt == content:
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
            name=f"Seeded v{new_version} (post-hotfix refresh)",
            meta_prompt=content,
            is_active=True,
            version=new_version,
        )


def noop_reverse(apps, schema_editor):
    """Reverse is a no-op — restoring the previous active row would require
    knowing which one was active before, and the deactivated row is still in
    the table for manual flip via the admin UI if needed.
    """


class Migration(migrations.Migration):
    dependencies = [
        ("voice", "0031_refresh_megaprompts_recrutopia_style"),
    ]

    operations = [
        migrations.RunPython(refresh_megaprompts, noop_reverse),
    ]
