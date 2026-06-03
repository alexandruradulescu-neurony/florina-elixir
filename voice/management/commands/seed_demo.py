"""
Demo data seed command.

Wipes and re-creates 3 demo sales agents + 3 clients + 3 visits scheduled on
the target date (default: today). Designed for the live-calls demo.

Usage:
    python manage.py seed_demo
    python manage.py seed_demo --date 2026-05-28
"""

from datetime import date as date_cls
from datetime import datetime, time, timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from voice.constants import VisitStatus
from voice.models import Client, User, Visit


class Command(BaseCommand):
    help = "Seed 3 demo agents + 3 clients + 3 visits for the live-calls demo."

    def add_arguments(self, parser):
        parser.add_argument(
            '--date',
            type=str,
            default=None,
            help='Date for the demo visits (YYYY-MM-DD). Defaults to today.',
        )

    def handle(self, *args, **opts):
        if opts['date']:
            target_date = date_cls.fromisoformat(opts['date'])
        else:
            target_date = timezone.now().date()

        # Wipe existing seeded demo data (idempotent)
        Visit.objects.filter(client__crm_id__startswith='DEMO-').delete()
        Client.objects.filter(crm_id__startswith='DEMO-').delete()
        User.objects.filter(username__startswith='demo_').delete()

        # Create 3 sales agents with Romanian names + the shared demo phone.
        # All 3 share +40722322358 (the demo handset that rings during the demo).
        DEMO_PHONE = '+40722322358'
        AGENTS = [
            ('demo_andrei', 'Andrei', 'Popescu'),
            ('demo_mihai',  'Mihai',  'Ionescu'),
            ('demo_vlad',   'Vlad',   'Marin'),
        ]
        agents = []
        for username, first, last in AGENTS:
            agent = User.objects.create(
                username=username,
                first_name=first,
                last_name=last,
                email=f"{username}@demo.local",
                phone_number=DEMO_PHONE,
                is_sales_agent=True,
            )
            agent.set_password('demo')
            agent.save()
            agents.append(agent)

        # Create 3 clients
        CLIENTS = [
            ('Acme Corporation',    'SaaS / B2B'),
            ('Quorum Industries',   'Manufacturing'),
            ('Clearwater Holdings', 'Financial services'),
        ]
        clients = []
        for i, (name, industry) in enumerate(CLIENTS, start=1):
            client = Client.objects.create(
                crm_id=f'DEMO-{i:03d}',
                name=name,
                industry=industry,
                domain=f"{name.lower().replace(' ', '')}.com",
            )
            clients.append(client)

        # Create 3 visits — one per agent, paired with a client; scheduled on target_date
        tz = timezone.get_current_timezone()
        for i, (agent, client) in enumerate(zip(agents, clients, strict=True), start=1):
            start = datetime.combine(target_date, time(10 + i, 0)).replace(tzinfo=tz)
            end = start + timedelta(hours=1)
            visit = Visit.objects.create(
                agent=agent,
                client=client,
                title=f"{client.name} – Q3 Planning",
                start_time=start,
                end_time=end,
                status=VisitStatus.PLANNED,
            )
            self.stdout.write(f"Visit {visit.id}: /manager/visits/{visit.id}/")

        self.stdout.write(self.style.SUCCESS(f'Demo data seeded for {target_date}.'))
        self.stdout.write('Next steps:')
        self.stdout.write('  1. Set phone numbers for demo_andrei, demo_mihai, demo_vlad in /admin/')
        self.stdout.write('  2. Update ELEVENLABS_AGENT_ID env var to new agent ID')
        self.stdout.write('  3. Open each visit URL above and paste pre/post prompts')
        self.stdout.write('  4. Click "Run pre-call" / "Run post-call" on demo day')
