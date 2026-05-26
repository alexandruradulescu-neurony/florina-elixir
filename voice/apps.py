from django.apps import AppConfig
import logging

logger = logging.getLogger(__name__)


class VoiceConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'voice'

    def ready(self):
        """
        Register scheduled jobs with APScheduler.
        Jobs are registered when runapscheduler management command is executed.
        Also auto-detect ngrok URL on startup.
        """
        # Jobs will be registered via django-apscheduler's runapscheduler command
        # This prevents issues with auto-starting scheduler during Django startup
        
        # Auto-detect ngrok URL on startup (only in DEBUG mode)
        from django.conf import settings
        if settings.DEBUG:
            try:
                from decouple import config
                from voice.utils import get_ngrok_url, build_webhook_url
                from voice.services import update_elevenlabs_webhook, get_elevenlabs_webhook_config
                
                # Prefer explicit NGROK_URL from .env over auto-detection
                ngrok_url = config('NGROK_URL', default='')
                if not ngrok_url:
                    ngrok_api_url = config('NGROK_API_URL', default='http://localhost:4040/api/tunnels')
                    ngrok_url = get_ngrok_url(ngrok_api_url)
                
                if ngrok_url:
                    webhook_url = build_webhook_url(ngrok_url)
                    logger.info(f"Ngrok detected: {ngrok_url}")
                    logger.info(f"Webhook URL: {webhook_url}")
                    
                    # Check if webhook needs updating
                    webhook_config = get_elevenlabs_webhook_config()
                    if webhook_config:
                        current_url = webhook_config.get('url', '')
                        if current_url != webhook_url:
                            logger.info(f"Webhook URL mismatch detected. Current: {current_url}, Should be: {webhook_url}")
                            logger.info("Run 'python manage.py detect_ngrok --update' to update automatically, or update manually in ElevenLabs dashboard")
                        else:
                            logger.info("Webhook URL is correctly configured")
                    else:
                        logger.info(f"Webhook URL to configure in ElevenLabs: {webhook_url}")
                        logger.info("Run 'python manage.py detect_ngrok' for configuration instructions")
                else:
                    logger.info("Ngrok not detected. Webhooks will not work until ngrok is started.")
                    logger.info("To start ngrok: ngrok http --url=sales-assist.ngrok.app 8003")
            except Exception as e:
                # Don't fail startup if ngrok detection fails
                logger.warning(f"Error detecting ngrok URL on startup: {e}")