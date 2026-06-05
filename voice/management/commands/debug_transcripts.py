"""
Management command to debug transcript issues.
Shows recent calls, transcript status, and webhook activity logs.
"""

import json
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from voice.models import ActivityLog, CallAttempt


class Command(BaseCommand):
    help = "Debug transcript issues by showing recent calls and webhook activity"

    def add_arguments(self, parser):
        parser.add_argument(
            "--hours", type=int, default=24, help="Number of hours to look back (default: 24)"
        )
        parser.add_argument("--call-id", type=str, help="Specific call attempt ID to debug")

    def handle(self, *args, **options):
        hours = options["hours"]
        call_id = options.get("call_id")

        self.stdout.write("=" * 80)
        self.stdout.write("Transcript Debugging Report")
        self.stdout.write("=" * 80)
        self.stdout.write("")

        if call_id:
            # Debug specific call
            try:
                call = CallAttempt.objects.get(id=call_id)
                self._debug_call(call)
            except CallAttempt.DoesNotExist:
                self.stdout.write(self.style.ERROR(f"Call attempt {call_id} not found"))
                return
        else:
            # Show recent completed calls
            time_threshold = timezone.now() - timedelta(hours=hours)
            recent_calls = CallAttempt.objects.filter(created_at__gte=time_threshold).order_by(
                "-created_at"
            )[:20]

            self.stdout.write(f"Found {recent_calls.count()} calls in last {hours} hours:")
            self.stdout.write("")

            for call in recent_calls:
                self._debug_call(call)
                self.stdout.write("-" * 80)
                self.stdout.write("")

            # Show webhook activity logs
            self.stdout.write("")
            self.stdout.write("=" * 80)
            self.stdout.write("Recent Webhook Activity Logs")
            self.stdout.write("=" * 80)
            self.stdout.write("")

            webhook_logs = ActivityLog.objects.filter(
                action__icontains="call completed", timestamp__gte=time_threshold
            ).order_by("-timestamp")[:10]

            for log in webhook_logs:
                self._debug_activity_log(log, options)
                self.stdout.write("-" * 80)
                self.stdout.write("")

    def _debug_call(self, call):
        """Debug a single call attempt."""
        self.stdout.write(f"Call ID: {call.id}")
        self.stdout.write(f"Visit: {call.visit.title if call.visit else 'N/A'}")
        self.stdout.write(f"Phase: {call.get_phase_display()}")
        self.stdout.write(f"Status: {call.status} ({call.get_status_display()})")
        self.stdout.write(f"External Call ID: {call.external_call_id or 'None'}")
        self.stdout.write(f"Created: {call.created_at}")
        self.stdout.write(f"Executed: {call.executed_at or 'Not executed'}")

        # Transcript status
        has_transcript = bool(call.transcript)
        transcript_length = len(call.transcript) if call.transcript else 0
        self.stdout.write(f"Transcript exists: {has_transcript}")
        self.stdout.write(f"Transcript length: {transcript_length} chars")

        if call.transcript:
            preview = (
                call.transcript[:200] + "..." if len(call.transcript) > 200 else call.transcript
            )
            self.stdout.write(f"Transcript preview: {preview}")
        else:
            self.stdout.write(self.style.WARNING("Transcript: [EMPTY]"))

        # Recording URL
        self.stdout.write(f"Recording URL: {call.recording_url or 'None'}")

        # Check for related activity logs
        related_logs = ActivityLog.objects.filter(
            visit=call.visit, action__icontains="call"
        ).order_by("-timestamp")[:3]

        if related_logs:
            self.stdout.write(f"Related activity logs: {related_logs.count()}")
            for log in related_logs:
                self.stdout.write(f"  - {log.timestamp}: {log.action} ({log.level})")

    def _debug_activity_log(self, log, options=None):
        """Debug an activity log entry."""
        self.stdout.write(f"Time: {log.timestamp}")
        self.stdout.write(f"Action: {log.action}")
        self.stdout.write(f"Level: {log.level}")

        if log.details:
            details = log.details
            self.stdout.write("Details:")

            # Show key fields
            if "call_id" in details:
                self.stdout.write(f"  - call_id: {details['call_id']}")
            if "has_transcript" in details:
                self.stdout.write(f"  - has_transcript: {details['has_transcript']}")
            if "transcript_length" in details:
                self.stdout.write(f"  - transcript_length: {details['transcript_length']}")
            if "webhook_type" in details:
                self.stdout.write(f"  - webhook_type: {details['webhook_type']}")

            # Show raw payload if available
            if "raw_payload" in details:
                payload = details["raw_payload"]
                self.stdout.write("  - raw_payload available: Yes")
                self.stdout.write(f"  - raw_payload type: {type(payload).__name__}")
                if isinstance(payload, dict):
                    self.stdout.write(f"  - raw_payload keys: {list(payload.keys())}")
                    # Show transcript data structure if present
                    data = payload.get("data", {})
                    if isinstance(data, dict):
                        transcript_data = data.get("transcript")
                        if transcript_data:
                            self.stdout.write(
                                f"  - transcript_data type: {type(transcript_data).__name__}"
                            )
                            if isinstance(transcript_data, dict):
                                self.stdout.write(
                                    f"  - transcript_data keys: {list(transcript_data.keys())}"
                                )
                                turns = transcript_data.get("turns", [])
                                if turns:
                                    self.stdout.write(
                                        f"  - transcript_data.turns: {len(turns)} turns"
                                    )
                                    # Show first turn structure
                                    if turns and isinstance(turns[0], dict):
                                        self.stdout.write(
                                            f"  - first turn keys: {list(turns[0].keys())}"
                                        )
                            elif isinstance(transcript_data, list):
                                self.stdout.write(
                                    f"  - transcript_data is a LIST with {len(transcript_data)} items"
                                )
                                if transcript_data and isinstance(transcript_data[0], dict):
                                    self.stdout.write(
                                        f"  - first item keys: {list(transcript_data[0].keys())}"
                                    )
                                # Show first few items
                                for idx, item in enumerate(transcript_data[:3]):
                                    if isinstance(item, dict):
                                        self.stdout.write(f"  - item {idx}: {list(item.keys())}")

            # Show full details as JSON if verbose
            verbosity = options.get("verbosity", 1) if options else 1
            if verbosity >= 2:
                self.stdout.write(f"  - Full details: {json.dumps(details, indent=2, default=str)}")
        else:
            self.stdout.write("Details: None")
