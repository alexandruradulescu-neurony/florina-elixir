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
                self.stderr.write(
                    self.style.WARNING(f"[{domain}] no active version; leaving {filename} as-is")
                )
                continue
            path = SEED_DIR / filename
            path.write_text(active.meta_prompt, encoding="utf-8")
            self.stdout.write(
                self.style.SUCCESS(f"[{domain}] wrote v{active.version} → {filename}")
            )
