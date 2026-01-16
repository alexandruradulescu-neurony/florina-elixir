"""
Custom middleware for the proj_mes_voice project.
"""
from django.conf import settings


class AllowNgrokMiddleware:
    """
    Middleware to automatically allow ngrok domains in development mode.
    This allows webhook testing without manually updating ALLOWED_HOSTS and CSRF_TRUSTED_ORIGINS.
    """
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        # Only in DEBUG mode
        if settings.DEBUG:
            host = request.get_host().split(':')[0]
            # Check if it's an ngrok domain
            if (host.endswith('.ngrok-free.dev') or 
                host.endswith('.ngrok.io') or 
                host.endswith('.ngrok.app') or
                host.endswith('.ngrok-free.app')):
                # Add to ALLOWED_HOSTS for this request
                if host not in settings.ALLOWED_HOSTS:
                    settings.ALLOWED_HOSTS.append(host)
                
                # Ngrok always uses HTTPS, so force HTTPS scheme
                # Also check X-Forwarded-Proto header (ngrok sends this)
                is_https = (
                    request.is_secure() or 
                    request.META.get('HTTP_X_FORWARDED_PROTO') == 'https' or
                    request.META.get('HTTP_X_FORWARDED_SSL') == 'on'
                )
                
                # Add to CSRF_TRUSTED_ORIGINS (ngrok always uses HTTPS)
                origin_https = f'https://{host}'
                if origin_https not in settings.CSRF_TRUSTED_ORIGINS:
                    settings.CSRF_TRUSTED_ORIGINS.append(origin_https)
        
        return self.get_response(request)

