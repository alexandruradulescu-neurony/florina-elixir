"""
URL configuration for the voice app.
"""
from django.urls import path
from . import views
from . import webhook_views

app_name = 'voice'

urlpatterns = [
    path('', views.HomeView.as_view(), name='home'),
    path('login/', views.CustomLoginView.as_view(), name='login'),
    path('logout/', views.CustomLogoutView.as_view(), name='logout'),
    # Google Calendar integration
    path('calendar/oauth/', views.GoogleCalendarOAuthView.as_view(), name='google_calendar_oauth'),
    path('calendar/callback/', views.GoogleCalendarCallbackView.as_view(), name='google_calendar_callback'),
    path('calendar/sync/', views.CalendarSyncTriggerView.as_view(), name='calendar_sync_trigger'),
    path('calendar/status/', views.CalendarSyncStatusView.as_view(), name='calendar_sync_status'),
    # Superuser (Manager) dashboards
    path('dashboard/admin/', views.SuperuserDashboardView.as_view(), name='superuser_dashboard'),
    path('dashboard/admin/test-call/', views.TestCallView.as_view(), name='test_call'),
    path('manager/prompts/', views.PromptListView.as_view(), name='prompt_list'),
    path('manager/prompts/<int:prompt_id>/edit/', views.PromptEditView.as_view(), name='prompt_edit'),
    path('manager/agents/', views.AgentManagementView.as_view(), name='agent_management'),
    path('manager/logs/', views.AuditLogExplorerView.as_view(), name='audit_logs'),
    path('manager/calls/', views.ProgrammedCallsView.as_view(), name='programmed_calls'),
    path('manager/calls/trigger/', views.ManualCallTriggerView.as_view(), name='manual_call_trigger'),
    path('webhooks/ngrok-status/', views.NgrokWebhookStatusView.as_view(), name='ngrok_webhook_status'),
    # Sales Agent dashboards
    path('dashboard/agent/', views.SalesAgentDashboardView.as_view(), name='sales_agent_dashboard'),
    path('meeting/<int:meeting_id>/', views.MeetingDetailView.as_view(), name='meeting_detail'),
    path('profile/', views.SalesAgentProfileView.as_view(), name='sales_agent_profile'),
    # Webhooks
    path('webhooks/elevenlabs/', webhook_views.ElevenLabsWebhookView.as_view(), name='elevenlabs_webhook'),
    path('webhooks/twilio/', webhook_views.TwilioWebhookView.as_view(), name='twilio_webhook'),
    path('webhooks/google-calendar/', webhook_views.GoogleCalendarWebhookView.as_view(), name='google_calendar_webhook'),
]

