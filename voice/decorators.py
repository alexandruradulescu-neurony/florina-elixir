"""
RBAC (Role-Based Access Control) decorators and mixins for the voice app.
"""
from django.contrib.auth.mixins import AccessMixin
from django.core.exceptions import PermissionDenied


class SuperuserRequiredMixin(AccessMixin):
    """Mixin that requires user to be a superuser."""
    
    def dispatch(self, request, *args, **kwargs):
        if not request.user.is_authenticated:
            return self.handle_no_permission()
        if not request.user.is_superuser:
            raise PermissionDenied("You must be a superuser to access this page.")
        return super().dispatch(request, *args, **kwargs)


class SalesAgentRequiredMixin(AccessMixin):
    """Mixin that requires user to be a sales agent."""
    
    def dispatch(self, request, *args, **kwargs):
        if not request.user.is_authenticated:
            return self.handle_no_permission()
        if not request.user.is_sales_agent:
            raise PermissionDenied("You must be a sales agent to access this page.")
        return super().dispatch(request, *args, **kwargs)
