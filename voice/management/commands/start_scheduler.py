"""
Management command to start the APScheduler with registered jobs.
This is a wrapper around django-apscheduler's runapscheduler command
that also registers our custom jobs.
"""
from django.core.management.base import BaseCommand
from django_apscheduler.jobstores import DjangoJobStore
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.interval import IntervalTrigger
from apscheduler.triggers.cron import CronTrigger
from voice import tasks


class Command(BaseCommand):
    help = 'Starts the APScheduler with registered jobs'

    def handle(self, *args, **options):
        self.stdout.write(self.style.SUCCESS('Starting APScheduler...'))
        
        scheduler = BackgroundScheduler()
        scheduler.add_jobstore(DjangoJobStore(), "default")
        
        # Schedule call check task every 5 minutes
        scheduler.add_job(
            tasks.check_and_trigger_calls,
            trigger=IntervalTrigger(minutes=5),
            id='check_and_trigger_calls',
            name='Check and trigger calls',
            replace_existing=True,
            jobstore='default',
        )
        
        # Schedule calendar sync every hour
        scheduler.add_job(
            tasks.sync_all_user_calendars,
            trigger=IntervalTrigger(hours=1),
            id='sync_all_user_calendars',
            name='Sync all user calendars',
            replace_existing=True,
            jobstore='default',
        )
        
        # Schedule pending calls sync every 15 minutes
        scheduler.add_job(
            tasks.sync_pending_calls,
            trigger=IntervalTrigger(minutes=15),
            id='sync_pending_calls',
            name='Sync pending calls from API',
            replace_existing=True,
            jobstore='default',
        )
        
        # Schedule daily client sync (2:00 AM)
        scheduler.add_job(
            tasks.sync_all_clients_task,
            trigger=CronTrigger(hour=2, minute=0),
            id='sync_all_clients',
            name='Sync all clients from CRM',
            replace_existing=True,
            jobstore='default',
        )

        # Schedule visit detection every 30 minutes
        scheduler.add_job(
            tasks.detect_visits_task,
            trigger=IntervalTrigger(minutes=30),
            id='detect_visits',
            name='Detect visits from calendar events',
            replace_existing=True,
            jobstore='default',
        )

        # Schedule visit pre-calls every 5 minutes
        scheduler.add_job(
            tasks.process_visit_pre_calls,
            trigger=IntervalTrigger(minutes=5),
            id='process_visit_pre_calls',
            name='Process visit pre-calls',
            replace_existing=True,
            jobstore='default',
        )

        # Schedule visit post-calls every 5 minutes
        scheduler.add_job(
            tasks.process_visit_post_calls,
            trigger=IntervalTrigger(minutes=5),
            id='process_visit_post_calls',
            name='Process visit post-calls',
            replace_existing=True,
            jobstore='default',
        )

        scheduler.start()
        self.stdout.write(self.style.SUCCESS('APScheduler started successfully!'))
        self.stdout.write('Registered jobs:')
        self.stdout.write('  - check_and_trigger_calls (every 5 minutes)')
        self.stdout.write('  - sync_all_user_calendars (every hour)')
        self.stdout.write('  - sync_pending_calls (every 15 minutes)')
        self.stdout.write('  - sync_all_clients (daily at 2:00 AM)')
        self.stdout.write('  - detect_visits (every 30 minutes)')
        self.stdout.write('  - process_visit_pre_calls (every 5 minutes)')
        self.stdout.write('  - process_visit_post_calls (every 5 minutes)')
        self.stdout.write('\nPress Ctrl+C to stop the scheduler.')
        
        try:
            # Keep the scheduler running
            import time
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            self.stdout.write(self.style.WARNING('\nStopping scheduler...'))
            scheduler.shutdown()
            self.stdout.write(self.style.SUCCESS('Scheduler stopped.'))

