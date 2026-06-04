import logging

from django.apps import AppConfig

logger = logging.getLogger(__name__)


class VoiceConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "voice"

    def ready(self):
        """App ready hook.

        Scheduled jobs are registered via django-apscheduler's
        ``runapscheduler`` management command — not here — to avoid the
        scheduler auto-starting inside every gunicorn worker, every
        management command, and every test process.

        The previous version of this method ran an ngrok auto-detection
        block on every startup that polled ``localhost:4040`` and printed
        webhook-configuration hints. That made sense in the era of local
        development against ngrok tunnels, but the app now lives on a
        real domain (``florina.vm.neurony.dev``); the auto-detect was
        dead noise on every worker boot. Removed entirely. OAuth flows
        that need an HTTPS callback in dev continue to resolve the
        ngrok URL on-demand inside the OAuth view, where the lookup is
        actually used.
        """
