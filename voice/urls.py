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
    path('manager/agents/<int:agent_id>/', views.AgentDetailView.as_view(), name='agent_detail'),
    path('manager/agents/add/', views.AgentCreateView.as_view(), name='agent_add'),
    path('manager/logs/', views.AuditLogExplorerView.as_view(), name='audit_logs'),
    path('manager/calls/', views.ProgrammedCallsView.as_view(), name='programmed_calls'),
    path('manager/calls/trigger/', views.ManualCallTriggerView.as_view(), name='manual_call_trigger'),
    path('webhooks/ngrok-status/', views.NgrokWebhookStatusView.as_view(), name='ngrok_webhook_status'),
    # Methodologies
    path('manager/methodologies/', views.MethodologyListView.as_view(), name='methodology_list'),
    path('manager/methodologies/add/', views.MethodologyCreateView.as_view(), name='methodology_create'),
    path('manager/methodologies/<int:methodology_id>/edit/', views.MethodologyEditView.as_view(), name='methodology_edit'),
    # Settings
    path('manager/settings/', views.GlobalSettingsView.as_view(), name='global_settings'),
    # Visits
    path('manager/visits/', views.VisitListView.as_view(), name='visit_list'),
    path('manager/visits/<int:visit_id>/', views.VisitDetailView.as_view(), name='visit_detail'),
    path('manager/visits/<int:visit_id>/call/<str:phase>/', views.VisitCallNowView.as_view(), name='visit_call_now'),
    path('manager/calendar/', views.VisitCalendarView.as_view(), name='visit_calendar'),
    # Agent methodology assignment
    path('manager/agents/<int:agent_id>/methodology/', views.AgentMethodologyView.as_view(), name='agent_methodology'),
    # Clients
    path('manager/clients/', views.ClientListView.as_view(), name='client_list'),
    path('manager/clients/add/', views.ClientCreateView.as_view(), name='client_create'),
    path('manager/clients/<int:client_id>/', views.ClientDetailView.as_view(), name='client_detail'),
    path('manager/clients/<int:client_id>/edit/', views.ClientEditView.as_view(), name='client_edit'),
    path('manager/clients/<int:client_id>/delete/', views.ClientDeleteView.as_view(), name='client_delete'),
    # Live Agent
    path('manager/agent-chat/', views.LiveAgentView.as_view(), name='live_agent'),
    path('manager/agent-chat/api/', views.LiveAgentChatAPI.as_view(), name='live_agent_api'),
    # Sales Agent dashboards
    path('dashboard/agent/', views.SalesAgentDashboardView.as_view(), name='sales_agent_dashboard'),
    path('meeting/<int:meeting_id>/', views.MeetingDetailView.as_view(), name='meeting_detail'),
    path('profile/', views.SalesAgentProfileView.as_view(), name='sales_agent_profile'),
    # Webhooks
    path('webhooks/elevenlabs/', webhook_views.ElevenLabsWebhookView.as_view(), name='elevenlabs_webhook'),
    path('webhooks/twilio/', webhook_views.TwilioWebhookView.as_view(), name='twilio_webhook'),
    path('webhooks/google-calendar/', webhook_views.GoogleCalendarWebhookView.as_view(), name='google_calendar_webhook'),
]

