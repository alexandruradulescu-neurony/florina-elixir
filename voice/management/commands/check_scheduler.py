"""
Management command to check what meetings the scheduler would find for calls.
"""
from datetime import datetime, time, timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from voice.constants import PRE_MEETING_OFFSETS, SCHEDULER_WINDOW
from voice.models import CallAttempt, Meeting, User
from voice.services import check_post_meeting_calls, check_pre_meeting_calls


class Command(BaseCommand):
    help = 'Check what meetings the scheduler would find for calls'

    def handle(self, *args, **options):
        self.stdout.write("=" * 60)
        self.stdout.write("SCHEDULER DIAGNOSTIC REPORT")
        self.stdout.write("=" * 60)

        now = timezone.now()
        self.stdout.write(f"\nCurrent time: {now}")
        self.stdout.write(f"Current date: {now.date()}")

        # Check for sales agents
        sales_agents = User.objects.filter(is_sales_agent=True)
        self.stdout.write(f"\nSales agents found: {sales_agents.count()}")
        for agent in sales_agents:
            self.stdout.write(f"  - {agent.username} (phone: {agent.phone_number or 'NOT SET'})")

        if sales_agents.count() == 0:
            self.stdout.write(self.style.WARNING("\nWARNING: No sales agents found! Mark users as sales agents in admin."))

        # Check meetings
        all_meetings = Meeting.objects.all()
        self.stdout.write(f"\nTotal meetings in database: {all_meetings.count()}")

        # Today's meetings
        today_start = timezone.make_aware(datetime.combine(now.date(), time.min))
        today_end = timezone.make_aware(datetime.combine(now.date(), time.max))
        today_meetings = Meeting.objects.filter(
            start_time__gte=today_start,
            start_time__lte=today_end
        )
        self.stdout.write(f"Today's meetings: {today_meetings.count()}")

        # Upcoming meetings (next 2 hours)
        future_meetings = Meeting.objects.filter(
            start_time__gte=now,
            start_time__lte=now + timedelta(hours=2)
        )
        self.stdout.write(f"Meetings in next 2 hours: {future_meetings.count()}")

        if future_meetings.count() > 0:
            self.stdout.write("\nUpcoming meetings:")
            for meeting in future_meetings:
                time_until = meeting.start_time - now
                minutes_until = int(time_until.total_seconds() / 60)
                self.stdout.write(f"  - {meeting.title} at {meeting.start_time} ({minutes_until} minutes from now)")
                self.stdout.write(f"    Agent: {meeting.agent.username}, Phone: {meeting.agent.phone_number or 'NOT SET'}")
                self.stdout.write(f"    Pre-call completed: {meeting.is_pre_call_completed}")

        # Check pre-meeting call logic
        self.stdout.write("\n" + "=" * 60)
        self.stdout.write("PRE-MEETING CALL CHECK")
        self.stdout.write("=" * 60)

        for offset in PRE_MEETING_OFFSETS:
            # Correct calculation: meeting.start_time + offset should be in window
            window_start = now - timedelta(minutes=offset) - timedelta(minutes=SCHEDULER_WINDOW / 2)
            window_end = now - timedelta(minutes=offset) + timedelta(minutes=SCHEDULER_WINDOW / 2)
            call_time_example = now - timedelta(minutes=offset)

            self.stdout.write(f"\nOffset: {offset} minutes")
            self.stdout.write(f"  Call should be made when meeting starts at: {call_time_example} ± {SCHEDULER_WINDOW/2} min")
            self.stdout.write(f"  Looking for meetings starting between: {window_start} and {window_end}")

            meetings_in_window = Meeting.objects.filter(
                start_time__gte=window_start,
                start_time__lte=window_end,
                agent__is_sales_agent=True
            )
            self.stdout.write(f"  Meetings in window: {meetings_in_window.count()}")

            for meeting in meetings_in_window:
                existing_attempt = CallAttempt.objects.filter(
                    meeting=meeting,
                    phase='PRE',
                    scheduled_offset_minutes=offset
                ).exists()
                self.stdout.write(f"    - {meeting.title} at {meeting.start_time}")
                self.stdout.write(f"      Pre-call completed: {meeting.is_pre_call_completed}")
                self.stdout.write(f"      Call attempt exists: {existing_attempt}")
                self.stdout.write(f"      Agent phone: {meeting.agent.phone_number or 'NOT SET'}")

        # Check what the actual functions return
        self.stdout.write("\n" + "=" * 60)
        self.stdout.write("SCHEDULER FUNCTION RESULTS")
        self.stdout.write("=" * 60)

        pre_calls = check_pre_meeting_calls()
        self.stdout.write(f"\nPre-meeting calls found: {len(pre_calls)}")
        for meeting, offset in pre_calls:
            self.stdout.write(f"  - {meeting.title} (offset: {offset} min, start: {meeting.start_time})")

        post_calls = check_post_meeting_calls()
        self.stdout.write(f"\nPost-meeting calls found: {len(post_calls)}")
        for meeting, offset in post_calls:
            self.stdout.write(f"  - {meeting.title} (offset: {offset} min, end: {meeting.end_time})")

        # Check call attempts
        self.stdout.write("\n" + "=" * 60)
        self.stdout.write("EXISTING CALL ATTEMPTS")
        self.stdout.write("=" * 60)

        recent_attempts = CallAttempt.objects.order_by('-created_at')[:10]
        self.stdout.write(f"\nRecent call attempts: {recent_attempts.count()}")
        for attempt in recent_attempts:
            self.stdout.write(f"  - {attempt.meeting.title} ({attempt.get_phase_display()}, {attempt.get_status_display()})")
            self.stdout.write(f"    Offset: {attempt.scheduled_offset_minutes} min, Created: {attempt.created_at}")

        self.stdout.write("\n" + "=" * 60)
        self.stdout.write("DIAGNOSTIC COMPLETE")
        self.stdout.write("=" * 60)
