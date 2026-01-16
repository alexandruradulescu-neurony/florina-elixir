"""
Management command to manually fetch transcripts from ElevenLabs API.
Useful when webhooks fail or transcripts are missing.
"""
from django.core.management.base import BaseCommand
from django.utils import timezone
from datetime import timedelta

from voice.models import CallAttempt
from voice.services import fetch_call_status_from_elevenlabs, sync_call_status_from_api


class Command(BaseCommand):
    help = 'Manually fetch transcripts from ElevenLabs API for calls without transcripts'

    def add_arguments(self, parser):
        parser.add_argument(
            '--call-id',
            type=str,
            help='Specific call attempt ID to fetch transcript for'
        )
        parser.add_argument(
            '--external-call-id',
            type=str,
            help='ElevenLabs conversation_id/call_id to fetch transcript for'
        )
        parser.add_argument(
            '--all-pending',
            action='store_true',
            help='Fetch transcripts for all completed calls without transcripts'
        )
        parser.add_argument(
            '--hours',
            type=int,
            default=24,
            help='Number of hours to look back when using --all-pending (default: 24)'
        )

    def handle(self, *args, **options):
        call_id = options.get('call_id')
        external_call_id = options.get('external_call_id')
        all_pending = options.get('all_pending')
        
        self.stdout.write("=" * 80)
        self.stdout.write("Fetch Transcripts from ElevenLabs API")
        self.stdout.write("=" * 80)
        self.stdout.write("")
        
        if call_id:
            # Fetch for specific call attempt
            try:
                call = CallAttempt.objects.get(id=call_id)
                self._fetch_for_call(call)
            except CallAttempt.DoesNotExist:
                self.stdout.write(self.style.ERROR(f"Call attempt {call_id} not found"))
                return
        
        elif external_call_id:
            # Fetch by external call ID
            call = CallAttempt.objects.filter(external_call_id=external_call_id).first()
            if call:
                self._fetch_for_call(call)
            else:
                self.stdout.write(self.style.ERROR(f"Call attempt with external_call_id {external_call_id} not found"))
                # Try to fetch directly from API anyway
                self.stdout.write(f"\nAttempting to fetch directly from API for external_call_id: {external_call_id}")
                result = fetch_call_status_from_elevenlabs(external_call_id)
                self._display_result(result, external_call_id)
        
        elif all_pending:
            # Fetch for all completed calls without transcripts
            hours = options['hours']
            time_threshold = timezone.now() - timedelta(hours=hours)
            
            calls = CallAttempt.objects.filter(
                status='COMPLETED',
                transcript__isnull=True
            ).exclude(
                external_call_id__isnull=True
            ).exclude(
                external_call_id=''
            ).filter(
                created_at__gte=time_threshold
            )
            
            self.stdout.write(f"Found {calls.count()} completed calls without transcripts in last {hours} hours")
            self.stdout.write("")
            
            success_count = 0
            fail_count = 0
            
            for call in calls:
                self.stdout.write(f"Fetching transcript for call {call.id} (external_id: {call.external_call_id})...")
                if self._fetch_for_call(call, verbose=False):
                    success_count += 1
                else:
                    fail_count += 1
                self.stdout.write("")
            
            self.stdout.write("=" * 80)
            self.stdout.write(f"Summary: {success_count} succeeded, {fail_count} failed")
            self.stdout.write("=" * 80)
        
        else:
            self.stdout.write(self.style.ERROR("Please specify --call-id, --external-call-id, or --all-pending"))
            self.stdout.write("\nUsage examples:")
            self.stdout.write("  python manage.py fetch_transcript --call-id 123")
            self.stdout.write("  python manage.py fetch_transcript --external-call-id abc123")
            self.stdout.write("  python manage.py fetch_transcript --all-pending --hours 48")

    def _fetch_for_call(self, call, verbose=True):
        """Fetch transcript for a specific call attempt."""
        if verbose:
            self.stdout.write(f"Call ID: {call.id}")
            self.stdout.write(f"Meeting: {call.meeting.title if call.meeting else 'N/A'}")
            self.stdout.write(f"External Call ID: {call.external_call_id or 'None'}")
            self.stdout.write(f"Current Status: {call.status}")
            self.stdout.write(f"Has Transcript: {bool(call.transcript)}")
            self.stdout.write("")
        
        if not call.external_call_id:
            if verbose:
                self.stdout.write(self.style.ERROR("No external_call_id available - cannot fetch from API"))
            return False
        
        if verbose:
            self.stdout.write(f"Fetching from ElevenLabs API...")
        
        # Use the sync function which handles all the logic
        result = sync_call_status_from_api(call)
        
        if result:
            call.refresh_from_db()
            if verbose:
                self.stdout.write(self.style.SUCCESS("Success!"))
                self.stdout.write(f"Status: {call.status}")
                self.stdout.write(f"Transcript length: {len(call.transcript) if call.transcript else 0} chars")
                if call.transcript:
                    preview = call.transcript[:200] + "..." if len(call.transcript) > 200 else call.transcript
                    try:
                        self.stdout.write(f"Transcript preview: {preview}")
                    except UnicodeEncodeError:
                        # Handle encoding issues on Windows console
                        preview_safe = preview.encode('ascii', 'replace').decode('ascii')
                        self.stdout.write(f"Transcript preview: {preview_safe}")
                if call.recording_url:
                    self.stdout.write(f"Recording URL: {call.recording_url}")
            return True
        else:
            if verbose:
                # Try to get more details from direct API call
                api_result = fetch_call_status_from_elevenlabs(call.external_call_id)
                self._display_result(api_result, call.external_call_id)
            return False

    def _display_result(self, result, call_id):
        """Display the result of a direct API fetch."""
        self.stdout.write(f"\nAPI Result for call_id: {call_id}")
        self.stdout.write(f"Success: {result.get('success', False)}")
        
        if result.get('success'):
            self.stdout.write(f"Status: {result.get('status', 'Unknown')}")
            transcript = result.get('transcript')
            if transcript:
                self.stdout.write(f"Transcript length: {len(transcript)} chars")
                preview = transcript[:200] + "..." if len(transcript) > 200 else transcript
                try:
                    self.stdout.write(f"Transcript preview: {preview}")
                except UnicodeEncodeError:
                    # Handle encoding issues on Windows console
                    preview_safe = preview.encode('ascii', 'replace').decode('ascii')
                    self.stdout.write(f"Transcript preview: {preview_safe}")
            else:
                self.stdout.write(self.style.WARNING("No transcript in API response"))
            
            recording_url = result.get('recording_url')
            if recording_url:
                self.stdout.write(f"Recording URL: {recording_url}")
        else:
            error = result.get('error', 'Unknown error')
            self.stdout.write(self.style.ERROR(f"Error: {error}"))
