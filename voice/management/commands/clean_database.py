"""
Django management command to clean the database.
Removes all logs, calls, visits, and calendar watches while preserving users and configuration.
"""

from django.core.management.base import BaseCommand
from django.db import transaction

from voice.models import (
    ActivityLog,
    CallAttempt,
    GoogleCalendarWatch,
    GoogleOauthCredential,
    User,
    Visit,
    VoicePrompt,
)


class Command(BaseCommand):
    help = (
        "Clean database: remove all logs, calls, visits, and calendar watches. "
        "Preserves users and configuration."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            "--force",
            action="store_true",
            help="Skip confirmation prompt",
        )

    def handle(self, *args, **options):
        if not options["force"]:
            self.stdout.write(
                self.style.WARNING(
                    "\nWARNING: This will delete:"
                    "\n  - All ActivityLog entries"
                    "\n  - All CallAttempt entries"
                    "\n  - All Visit entries"
                    "\n  - All GoogleCalendarWatch entries"
                    "\n  - All GoogleOauthCredential entries (OAuth tokens)"
                    "\n\nThis will NOT delete:"
                    "\n  - User accounts"
                    "\n  - VoicePrompt entries (configuration)"
                    "\n\nAre you sure you want to continue? (yes/no): "
                )
            )
            confirm = input()
            if confirm.lower() != "yes":
                self.stdout.write(self.style.ERROR("Operation cancelled."))
                return

        with transaction.atomic():
            # Count before deletion
            activity_logs_count = ActivityLog.objects.count()
            call_attempts_count = CallAttempt.objects.count()
            visits_count = Visit.objects.count()
            calendar_watches_count = GoogleCalendarWatch.objects.count()
            oauth_credentials_count = GoogleOauthCredential.objects.count()

            # Delete in order (respecting foreign key constraints)
            self.stdout.write("Deleting ActivityLog entries...")
            ActivityLog.objects.all().delete()
            self.stdout.write(
                self.style.SUCCESS(f"  Deleted {activity_logs_count} ActivityLog entries")
            )

            self.stdout.write("Deleting CallAttempt entries...")
            CallAttempt.objects.all().delete()
            self.stdout.write(
                self.style.SUCCESS(f"  Deleted {call_attempts_count} CallAttempt entries")
            )

            self.stdout.write("Deleting Visit entries...")
            Visit.objects.all().delete()
            self.stdout.write(self.style.SUCCESS(f"  Deleted {visits_count} Visit entries"))

            self.stdout.write("Deleting GoogleCalendarWatch entries...")
            GoogleCalendarWatch.objects.all().delete()
            self.stdout.write(
                self.style.SUCCESS(
                    f"  Deleted {calendar_watches_count} GoogleCalendarWatch entries"
                )
            )

            self.stdout.write("Deleting GoogleOauthCredential entries...")
            GoogleOauthCredential.objects.all().delete()
            self.stdout.write(
                self.style.SUCCESS(
                    f"  Deleted {oauth_credentials_count} GoogleOauthCredential entries"
                )
            )

            # Show what was preserved
            users_count = User.objects.count()
            prompts_count = VoicePrompt.objects.count()

            self.stdout.write(
                self.style.SUCCESS(
                    f"\nDatabase cleaned successfully!"
                    f"\n\nPreserved:"
                    f"\n  - {users_count} User accounts"
                    f"\n  - {prompts_count} VoicePrompt entries (configuration)"
                    f"\n\nNote: Users will need to re-authenticate with Google Calendar to sync visits."
                )
            )
