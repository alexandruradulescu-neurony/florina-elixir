"""
Custom template tags for the voice app.
"""
from django import template

register = template.Library()


@register.filter
def daisyui_alert_class(message_tag):
    """
    Map Django message tags to DaisyUI alert classes.

    Django tags: error, warning, info, success, debug
    DaisyUI classes: alert-error, alert-warning, alert-info, alert-success
    """
    mapping = {
        'error': 'alert-error',
        'warning': 'alert-warning',
        'info': 'alert-info',
        'success': 'alert-success',
        'debug': 'alert-info',
    }
    return mapping.get(message_tag, 'alert-info')

