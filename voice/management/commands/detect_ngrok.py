"""
Management command to detect current ngrok URL and display webhook configuration.
"""
from django.core.management.base import BaseCommand

from voice.services import get_elevenlabs_webhook_config, update_elevenlabs_webhook
from voice.utils import build_webhook_url, get_ngrok_url, validate_ngrok_url


class Command(BaseCommand):
    help = 'Detect current ngrok URL and display webhook configuration information'

    def add_arguments(self, parser):
        parser.add_argument(
            '--update',
            action='store_true',
            help='Attempt to update ElevenLabs webhook URL automatically (if API available)',
        )
        parser.add_argument(
            '--api-url',
            type=str,
            default='http://localhost:4040/api/tunnels',
            help='Ngrok API URL (default: http://localhost:4040/api/tunnels)',
        )

    def handle(self, *args, **options):
        self.stdout.write(self.style.SUCCESS('=' * 60))
        self.stdout.write(self.style.SUCCESS('Ngrok URL Detection'))
        self.stdout.write(self.style.SUCCESS('=' * 60))

        # Get ngrok URL
        api_url = options['api_url']
        self.stdout.write(f'\nQuerying ngrok API at: {api_url}')

        ngrok_url = get_ngrok_url(api_url)

        if not ngrok_url:
            self.stdout.write(self.style.ERROR('\n[ERROR] Ngrok is not running or no tunnel found!'))
            self.stdout.write('\nTo start ngrok:')
            self.stdout.write('  ngrok http 8000')
            self.stdout.write('\nThen run this command again.')
            return

        self.stdout.write(self.style.SUCCESS(f'\n[OK] Ngrok URL detected: {ngrok_url}'))

        # Build webhook URL
        webhook_url = build_webhook_url(ngrok_url)
        self.stdout.write(f'\nWebhook URL: {webhook_url}')

        # Check if URL is valid ngrok URL
        if validate_ngrok_url(ngrok_url):
            self.stdout.write(self.style.SUCCESS('[OK] Valid ngrok URL format'))
        else:
            self.stdout.write(self.style.WARNING('[WARNING] URL does not match expected ngrok pattern'))

        # Display configuration instructions
        self.stdout.write('\n' + '=' * 60)
        self.stdout.write('ElevenLabs Webhook Configuration')
        self.stdout.write('=' * 60)

        # Try to get current webhook config (if API available)
        webhook_config = get_elevenlabs_webhook_config()

        if webhook_config:
            current_url = webhook_config.get('url', 'Not configured')
            self.stdout.write(f'\nCurrent webhook URL in ElevenLabs: {current_url}')

            if current_url != webhook_url:
                self.stdout.write(self.style.WARNING('\n[WARNING] Webhook URL mismatch!'))
                self.stdout.write(f'  Current: {current_url}')
                self.stdout.write(f'  Should be: {webhook_url}')

                if options['update']:
                    self.stdout.write('\nAttempting to update webhook URL...')
                    result = update_elevenlabs_webhook(webhook_url)
                    if result.get('success'):
                        self.stdout.write(self.style.SUCCESS('[OK] Webhook URL updated successfully!'))
                    else:
                        self.stdout.write(self.style.ERROR(f'[ERROR] Failed to update: {result.get("error", "Unknown error")}'))
                else:
                    self.stdout.write('\nTo update automatically, run:')
                    self.stdout.write('  python manage.py detect_ngrok --update')
            else:
                self.stdout.write(self.style.SUCCESS('\n[OK] Webhook URL is correctly configured!'))
        else:
            # No API available - show manual instructions
            self.stdout.write('\nManual Configuration Required:')
            self.stdout.write('1. Go to ElevenLabs Dashboard -> Developers -> Webhooks')
            self.stdout.write('2. Add or edit webhook endpoint')
            self.stdout.write(f'3. Set URL to: {webhook_url}')
            self.stdout.write('4. Select event type: post_call_transcription')
            self.stdout.write('5. Save the webhook')

        # Display copy-paste ready URL
        self.stdout.write('\n' + '=' * 60)
        self.stdout.write('Copy this URL to configure in ElevenLabs:')
        self.stdout.write('=' * 60)
        self.stdout.write(self.style.SUCCESS(webhook_url))
        self.stdout.write('')
