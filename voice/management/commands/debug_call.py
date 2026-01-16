"""
Management command to debug a specific call failure.
"""
from django.core.management.base import BaseCommand
from voice.models import CallAttempt, ActivityLog
from voice.utils import format_phone_number
from decouple import config
from django.utils import timezone


class Command(BaseCommand):
    help = 'Debug a specific call failure'

    def add_arguments(self, parser):
        parser.add_argument('call_id', type=int, help='CallAttempt ID to debug')

    def handle(self, *args, **options):
        call_id = options['call_id']
        
        try:
            call = CallAttempt.objects.get(id=call_id)
        except CallAttempt.DoesNotExist:
            self.stdout.write(self.style.ERROR(f'CallAttempt {call_id} not found'))
            return
        
        self.stdout.write("=" * 60)
        self.stdout.write(f"DEBUGGING CALL ATTEMPT #{call_id}")
        self.stdout.write("=" * 60)
        
        self.stdout.write(f"\nCall Details:")
        self.stdout.write(f"  Status: {call.status}")
        self.stdout.write(f"  Phase: {call.get_phase_display()}")
        self.stdout.write(f"  Offset: {call.scheduled_offset_minutes} minutes")
        self.stdout.write(f"  External Call ID: {call.external_call_id or 'None'}")
        self.stdout.write(f"  Created: {call.created_at}")
        self.stdout.write(f"  Executed: {call.executed_at or 'Not executed'}")
        
        self.stdout.write(f"\nMeeting Details:")
        self.stdout.write(f"  Title: {call.meeting.title}")
        self.stdout.write(f"  Agent: {call.meeting.agent.username}")
        self.stdout.write(f"  Agent Phone: {call.meeting.agent.phone_number}")
        
        # Check phone number format
        formatted_phone = format_phone_number(call.meeting.agent.phone_number)
        self.stdout.write(f"\nPhone Number Validation:")
        self.stdout.write(f"  Original: {call.meeting.agent.phone_number}")
        self.stdout.write(f"  Formatted: {formatted_phone or 'INVALID'}")
        if not formatted_phone:
            self.stdout.write(self.style.ERROR("  [X] Phone number format is invalid!"))
        else:
            self.stdout.write(self.style.SUCCESS("  [OK] Phone number format is valid"))
        
        # Check ElevenLabs configuration
        self.stdout.write(f"\nElevenLabs Configuration:")
        api_key = config('ELEVENLABS_API_KEY', default='')
        agent_id = config('ELEVENLABS_AGENT_ID', default='')
        phone_id = config('ELEVENLABS_PHONE_NUMBER_ID', default='')
        
        self.stdout.write(f"  API Key: {'SET' if api_key else self.style.ERROR('MISSING')}")
        self.stdout.write(f"  Agent ID: {agent_id or self.style.ERROR('MISSING')}")
        self.stdout.write(f"  Phone Number ID: {phone_id or self.style.ERROR('MISSING')}")
        
        if not api_key or not agent_id or not phone_id:
            self.stdout.write(self.style.ERROR("\n[X] Missing ElevenLabs configuration!"))
        
        # Check activity logs
        self.stdout.write(f"\nActivity Logs (related to this call):")
        logs = ActivityLog.objects.filter(
            meeting=call.meeting,
            timestamp__gte=call.created_at - timezone.timedelta(minutes=5)
        ).order_by('timestamp')
        
        if logs.exists():
            for log in logs:
                level_style = {
                    'ERROR': self.style.ERROR,
                    'WARNING': self.style.WARNING,
                    'INFO': self.style.SUCCESS,
                }.get(log.level, lambda x: x)
                
                self.stdout.write(f"  [{log.timestamp}] {level_style(log.level)}: {log.action}")
                if log.details:
                    self.stdout.write(f"    Details: {log.details}")
        else:
            self.stdout.write("  No related activity logs found")
        
        self.stdout.write("\n" + "=" * 60)
