"""
Management command to start the APScheduler with registered jobs.
This is a wrapper around django-apscheduler's runapscheduler command
that also registers our custom jobs.
"""
from django.core.management.base import BaseCommand
from django_apscheduler.jobstores import DjangoJobStore
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.interval import IntervalTrigger
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
        
        scheduler.start()
        self.stdout.write(self.style.SUCCESS('APScheduler started successfully!'))
        self.stdout.write('Registered jobs:')
        self.stdout.write('  - check_and_trigger_calls (every 5 minutes)')
        self.stdout.write('  - sync_all_user_calendars (every hour)')
        self.stdout.write('  - sync_pending_calls (every 15 minutes)')
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

