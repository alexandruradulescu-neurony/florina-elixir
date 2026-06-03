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
                    MegaPrompt.objects.filter(domain=domain).aggregate(Max("version"))[
                        "version__max"
                    ]
                    or 0
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
