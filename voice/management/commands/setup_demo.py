"""
One-shot demo setup for a fresh clone.

After `pip install`, `migrate`, and an `.env` with the right keys, the
boss/colleague just runs:

    python manage.py setup_demo

…and gets:
  - Superuser admin / admin123
  - 3 sales agents (demo_andrei, demo_mihai, demo_vlad), password "demo",
    all sharing the demo phone +40722322358
  - 3 Romanian clients (Domus Imobiliare, Farmaciile Vitalis, Logix Transport)
    with the right status (nou / existent) and industry
  - 3 visits on 2026-05-28 at 11:00, 12:00, 13:00 — one per agent
  - 3 Methodology rows linked to the visits
  - All 12 Romanian prompts populated on the visits
  - V36 (Domus) pre/post prompts in the new "Florina knows the answers"
    format with expectations + reactions

Options:
  --date YYYY-MM-DD   Move all 3 visits to this date (default: 2026-05-28).
  --admin-password X  Override admin password (default: admin123).
  --skip-admin        Don't create or update the admin user.

The command is safe to re-run: it overwrites demo content in place via
update_or_create / direct field assignment, but does not touch unrelated
data.
"""

from django.core.management import call_command
from django.core.management.base import BaseCommand

from voice.models import User


class Command(BaseCommand):
    help = "Bootstrap the demo: admin + agents + clients + visits + content."

    def add_arguments(self, parser):
        parser.add_argument('--date', type=str, default='2026-05-28',
                            help='Date for the 3 demo visits. Default: 2026-05-28')
        parser.add_argument('--admin-password', type=str, default='admin123',
                            help='Password for the admin superuser.')
        parser.add_argument('--skip-admin', action='store_true',
                            help='Do not create or update the admin superuser.')

    def handle(self, *args, **opts):
        target_date = opts['date']
        admin_password = opts['admin_password']
        skip_admin = opts['skip_admin']

        # ─── Step 1: admin superuser ───
        if not skip_admin:
            admin, created = User.objects.get_or_create(
                username='admin',
                defaults={
                    'email': 'admin@demo.local',
                    'is_superuser': True,
                    'is_staff': True,
                    'first_name': 'Demo',
                    'last_name': 'Manager',
                },
            )
            # Always set the password + flags so this command idempotently
            # restores a known-good admin even if someone changed them.
            admin.is_superuser = True
            admin.is_staff = True
            admin.set_password(admin_password)
            admin.save()
            if created:
                self.stdout.write(self.style.SUCCESS(
                    f"✓ Created admin superuser: admin / {admin_password}"
                ))
            else:
                self.stdout.write(self.style.SUCCESS(
                    f"✓ Reset admin password: admin / {admin_password}"
                ))

        # ─── Step 2: agents + clients + visits (seed_demo) ───
        self.stdout.write("")
        self.stdout.write("Running seed_demo…")
        call_command('seed_demo', date=target_date)

        # ─── Step 3: Romanian rename + statuses + methodologies + 12 prompts ───
        self.stdout.write("")
        self.stdout.write("Running seed_demo_content…")
        call_command('seed_demo_content')

        # ─── Step 4: handoff summary ───
        self.stdout.write("")
        self.stdout.write(self.style.SUCCESS("━" * 70))
        self.stdout.write(self.style.SUCCESS("DEMO SETUP COMPLETE"))
        self.stdout.write(self.style.SUCCESS("━" * 70))
        self.stdout.write("")
        # Look up current visit IDs (auto-increment, change each wipe+reseed)
        from voice.models import Visit as _V
        visits = _V.objects.filter(client__crm_id__startswith='DEMO-').select_related('client').order_by('start_time')
        self.stdout.write("Login URLs:")
        self.stdout.write("  /                      → role-aware landing")
        self.stdout.write("  /admin/                → Django admin")
        self.stdout.write("  /dashboard/admin/      → manager dashboard")
        self.stdout.write("  /manager/visits/       → visits list")
        self.stdout.write("  /manager/calendar/     → calendar (week + day)")
        for v in visits:
            client_name = v.client.name if v.client else '?'
            self.stdout.write(f"  /manager/visits/{v.id}/    → {client_name} visit detail")
        self.stdout.write("")
        self.stdout.write("Credentials:")
        self.stdout.write(f"  admin        / {admin_password}    (superuser)")
        self.stdout.write("  demo_andrei  / demo         (Andrei Popescu, +40722322358)")
        self.stdout.write("  demo_mihai   / demo         (Mihai Ionescu, +40722322358)")
        self.stdout.write("  demo_vlad    / demo         (Vlad Marin, +40722322358)")
        self.stdout.write("")
        first_visit = visits.first() if visits else None
        first_url = f"/manager/visits/{first_visit.id}/" if first_visit else "/manager/visits/"
        self.stdout.write("Next steps:")
        self.stdout.write("  1. Verify .env has ELEVENLABS_API_KEY, ELEVENLABS_AGENT_ID,")
        self.stdout.write("     ELEVENLABS_PHONE_NUMBER_ID, ANTHROPIC_API_KEY all set.")
        self.stdout.write("  2. Start ngrok: ngrok http --url=sales-assist.ngrok.app 8007")
        self.stdout.write("     (or change the URL in ElevenLabs dashboard webhook config)")
        self.stdout.write("  3. python manage.py runserver 0.0.0.0:8007")
        self.stdout.write(f"  4. Open {first_url} and click 'Run pre-call'")
        self.stdout.write("")
