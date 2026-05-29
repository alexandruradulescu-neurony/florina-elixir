"""
Views for the voice app.
Using class-based views (thing view pattern) following DRY principles.
"""
import logging
from django.shortcuts import render, redirect
from django.views.generic import View
from django.contrib.auth import logout
from django.contrib.auth.views import LoginView
from django.contrib.auth.mixins import LoginRequiredMixin
from django.views.decorators.csrf import csrf_protect
from django.utils.decorators import method_decorator
from django.contrib import messages
from django.urls import reverse
from django.utils import timezone
from datetime import timedelta, datetime, time
from google_auth_oauthlib.flow import Flow
from google.oauth2.credentials import Credentials

from .services import sync_google_calendar, log_activity, format_prompt_with_context, format_first_message_with_context, get_elevenlabs_webhook_config, update_elevenlabs_webhook
from .selectors import (
    get_recent_activity_logs,
    get_system_statistics,
    get_recent_calls,
    get_failed_calls_today,
    get_all_meetings,
    get_activity_logs_filtered,
    get_agent_meetings,
    get_agent_call_statistics,
    get_upcoming_meetings_for_agent,
    get_agent_timeline_data,
    get_dashboard_visit_summary,
    get_agent_readiness,
    get_dashboard_action_items,
    get_weekly_summary,
    get_recent_post_call_summaries,
    get_next_upcoming_visit,
    get_visits_for_date,
    get_clients_with_stats,
    get_client_detail,
    get_agent_visits,
)
from .models import Meeting, VoicePrompt, User, CallAttempt, Methodology, GlobalSettings, Visit, Client
from .decorators import SuperuserRequiredMixin, SalesAgentRequiredMixin
from .forms import AgentCreateForm, MethodologyForm, GlobalSettingsForm, VisitManagerNotesForm, AgentMethodologyForm, ClientForm
from .utils import get_ngrok_url, validate_ngrok_url, build_webhook_url
from voice import placeholders

logger = logging.getLogger(__name__)


class HomeView(LoginRequiredMixin, View):
    """Home page view - redirects based on user role."""
    
    def get(self, request):
        if request.user.is_superuser:
            return redirect('voice:superuser_dashboard')
        elif request.user.is_sales_agent:
            return redirect('voice:sales_agent_dashboard')
        else:
            return render(request, 'voice/home.html')


class CustomLoginView(LoginView):
    """Custom login view with template and remember me functionality."""
    template_name = 'voice/login.html'
    redirect_authenticated_user = True
    
    def form_valid(self, form):
        """Handle successful login with remember me option."""
        remember_me = self.request.POST.get('remember_me', False)
        
        # Let parent class handle the login
        response = super().form_valid(form)
        
        # Set session expiry based on remember me
        if remember_me:
            # Set session to expire in 2 weeks
            self.request.session.set_expiry(timedelta(days=14))
        else:
            # Session expires when browser closes
            self.request.session.set_expiry(0)
        
        return response


@method_decorator(csrf_protect, name='dispatch')
class CustomLogoutView(View):
    """Custom logout view with template."""
    
    def post(self, request):
        """Handle POST request for logout."""
        logout(request)
        return render(request, 'voice/logged_out.html')
    
    def get(self, request):
        """Handle GET request for logout (also logs out)."""
        logout(request)
        return render(request, 'voice/logged_out.html')


class GoogleCalendarOAuthView(LoginRequiredMixin, View):
    """Initiate Google OAuth flow for calendar access."""
    
    def get(self, request):
        """Start OAuth flow."""
        from decouple import config
        
        client_id = config('GOOGLE_CLIENT_ID', default='')
        client_secret = config('GOOGLE_CLIENT_SECRET', default='')
        
        # Try to use ngrok URL for HTTPS (required by Google OAuth)
        ngrok_url = get_ngrok_url()
        if ngrok_url:
            # Use ngrok HTTPS URL for OAuth callback
            redirect_uri = f"{ngrok_url}/calendar/callback/"
            logger.info(f"OAuth flow - Using ngrok URL: {redirect_uri}")
        else:
            # Fall back to configured redirect URI or request URI
            redirect_uri = config('GOOGLE_REDIRECT_URI', default=request.build_absolute_uri(reverse('voice:google_calendar_callback')))
            # Check if it's HTTP (not allowed by Google OAuth)
            if redirect_uri.startswith('http://') and 'localhost' in redirect_uri:
                messages.error(
                    request, 
                    'OAuth requires HTTPS. Please start ngrok and run "python manage.py detect_ngrok" to configure it, '
                    'or update GOOGLE_REDIRECT_URI in .env to use an HTTPS URL.'
                )
                return redirect('voice:calendar_sync_status')
        
        # Debug logging
        logger.info(f"OAuth flow - Client ID: {client_id[:30]}... (length: {len(client_id)})")
        logger.info(f"OAuth flow - Client Secret: {'*' * 10}... (length: {len(client_secret)})")
        logger.info(f"OAuth flow - Redirect URI: {redirect_uri}")
        
        if not client_id or not client_secret:
            logger.error("OAuth flow - Missing credentials!")
            messages.error(request, 'Google Calendar integration is not configured.')
            return redirect('voice:calendar_sync_status')
        
        # Validate client_id format
        if 'your-google-client-id' in client_id or client_id == '':
            logger.error(f"OAuth flow - Invalid client_id detected: {client_id}")
            messages.error(request, 'Google Calendar Client ID is not properly configured. Please check your .env file.')
            return redirect('voice:calendar_sync_status')
        
        flow = Flow.from_client_config(
            {
                "web": {
                    "client_id": client_id,
                    "client_secret": client_secret,
                    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                    "token_uri": "https://oauth2.googleapis.com/token",
                    "redirect_uris": [redirect_uri]
                }
            },
            scopes=['https://www.googleapis.com/auth/calendar.readonly']
        )
        flow.redirect_uri = redirect_uri
        
        authorization_url, state = flow.authorization_url(
            access_type='offline',
            include_granted_scopes='true',
            prompt='consent'
        )
        
        # Store state in session for verification
        request.session['google_oauth_state'] = state
        
        return redirect(authorization_url)


class GoogleCalendarCallbackView(LoginRequiredMixin, View):
    """Handle Google OAuth callback."""
    
    def get(self, request):
        """Process OAuth callback and store credentials."""
        from decouple import config
        # Import get_ngrok_url locally to avoid scoping issues
        from .utils import get_ngrok_url
        
        state = request.session.get('google_oauth_state')
        if not state or state != request.GET.get('state'):
            messages.error(request, 'Invalid OAuth state. Please try again.')
            return redirect('voice:calendar_sync_status')
        
        client_id = config('GOOGLE_CLIENT_ID', default='')
        client_secret = config('GOOGLE_CLIENT_SECRET', default='')
        
        # Use the same redirect URI logic as OAuth view (ngrok if available)
        ngrok_url = get_ngrok_url()
        if ngrok_url:
            redirect_uri = f"{ngrok_url}/calendar/callback/"
        else:
            redirect_uri = config('GOOGLE_REDIRECT_URI', default=request.build_absolute_uri(reverse('voice:google_calendar_callback')))
        
        flow = Flow.from_client_config(
            {
                "web": {
                    "client_id": client_id,
                    "client_secret": client_secret,
                    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                    "token_uri": "https://oauth2.googleapis.com/token",
                    "redirect_uris": [redirect_uri]
                }
            },
            scopes=['https://www.googleapis.com/auth/calendar.readonly']
        )
        flow.redirect_uri = redirect_uri
        
        try:
            # Build authorization_response URL - use ngrok URL if available to ensure HTTPS
            if ngrok_url:
                # Use the ngrok URL for the authorization response
                authorization_response = f"{ngrok_url}{request.get_full_path()}"
                logger.info(f"OAuth callback - Using ngrok URL for authorization_response: {authorization_response}")
            else:
                # Fall back to request URI, but ensure HTTPS if possible
                authorization_response = request.build_absolute_uri()
                # Check if we need to force HTTPS (for ngrok or reverse proxy)
                if request.META.get('HTTP_X_FORWARDED_PROTO') == 'https':
                    authorization_response = authorization_response.replace('http://', 'https://', 1)
                logger.info(f"OAuth callback - Using request URI: {authorization_response}")
            
            flow.fetch_token(authorization_response=authorization_response)
            
            credentials = flow.credentials
            
            # Save or update credentials in database (enables background tasks)
            from .models import GoogleOauthCredential
            GoogleOauthCredential.objects.update_or_create(
                user=request.user,
                defaults={
                    'token': credentials.token,
                    'refresh_token': credentials.refresh_token,
                    'token_uri': credentials.token_uri,
                    'client_id': credentials.client_id,
                    'client_secret': credentials.client_secret,
                    'scopes': list(credentials.scopes),
                    'expires_at': (
                        timezone.make_aware(credentials.expiry) if timezone.is_naive(credentials.expiry) 
                        else credentials.expiry
                    ).astimezone(timezone.utc) if credentials.expiry else None,
                }
            )
            
            # Also keep session for backward compatibility during transition
            request.session['google_credentials'] = {
                'token': credentials.token,
                'refresh_token': credentials.refresh_token,
                'token_uri': credentials.token_uri,
                'client_id': credentials.client_id,
                'client_secret': credentials.client_secret,
                'scopes': credentials.scopes
            }
            
            # Clear OAuth state
            del request.session['google_oauth_state']
            
            log_activity(
                user=request.user,
                action="Google Calendar OAuth completed",
                level='INFO'
            )
            
            messages.success(request, 'Google Calendar connected successfully!')
            
            # Set up push notifications (watch) for real-time updates
            try:
                from .services import setup_google_calendar_watch
                
                # Get webhook URL (use ngrok if available, otherwise use configured URL)
                # Reuse ngrok_url from above (already set in this function scope)
                if ngrok_url:
                    webhook_url = f"{ngrok_url}/webhooks/google-calendar/"
                else:
                    from decouple import config
                    webhook_url = config('GOOGLE_CALENDAR_WEBHOOK_URL', default='')
                    if not webhook_url:
                        # Fallback to request URL
                        webhook_url = request.build_absolute_uri(reverse('voice:google_calendar_webhook'))
                
                watch_result = setup_google_calendar_watch(request.user, webhook_url, session=request.session)
                if watch_result.get('success'):
                    messages.info(request, 'Real-time calendar notifications enabled!')
                else:
                    logger.warning(f"Failed to set up calendar watch: {watch_result.get('error')}")
            except Exception as e:
                logger.error(f"Error setting up calendar watch: {e}", exc_info=True)
                # Don't fail the OAuth flow if watch setup fails
            
            return redirect('voice:calendar_sync_status')
            
        except Exception as e:
            log_activity(
                user=request.user,
                action="Google Calendar OAuth failed",
                details={'error': str(e)},
                level='ERROR'
            )
            messages.error(request, f'Failed to connect Google Calendar: {str(e)}')
            return redirect('voice:calendar_sync_status')


class CalendarSyncTriggerView(LoginRequiredMixin, View):
    """Trigger manual calendar sync."""
    
    def post(self, request):
        """Trigger calendar sync for the current user."""
        if not request.user.is_sales_agent:
            messages.error(request, 'Only sales agents can sync calendars.')
            return redirect('voice:calendar_sync_status')
        
        # Sync today's meetings only (start of day to end of day in UTC)
        now = timezone.now()
        today_start = timezone.make_aware(datetime.combine(now.date(), time.min))
        today_end = timezone.make_aware(datetime.combine(now.date(), time.max))
        
        results = sync_google_calendar(
            user=request.user,
            time_min=today_start,
            time_max=today_end,
            session=request.session
        )
        
        if results['errors']:
            messages.warning(
                request,
                f"Sync completed with {results['created']} created, {results['updated']} updated, "
                f"but {len(results['errors'])} errors occurred."
            )
        else:
            messages.success(
                request,
                f"Sync completed: {results['created']} meetings created, {results['updated']} meetings updated."
            )
        
        return redirect('voice:calendar_sync_status')


class CalendarSyncStatusView(LoginRequiredMixin, View):
    """Display calendar sync status and recent meetings."""
    
    def get(self, request):
        """Show sync status dashboard."""
        # Check if user has Google credentials
        has_credentials = 'google_credentials' in request.session
        
        # Get user's meetings
        meetings = Meeting.objects.filter(agent=request.user).order_by('-start_time')[:20]
        
        # Get recent activity logs
        recent_logs = get_recent_activity_logs(limit=10)
        
        context = {
            'has_credentials': has_credentials,
            'meetings': meetings,
            'recent_logs': recent_logs,
            'is_sales_agent': request.user.is_sales_agent,
        }
        
        return render(request, 'voice/calendar_sync_status.html', context)


# ============================================================================
# Superuser (Manager) Views
# ============================================================================

class SuperuserDashboardView(SuperuserRequiredMixin, View):
    """Sales manager dashboard with business intelligence."""

    def get(self, request):
        today = timezone.now().date()

        visit_summary = get_dashboard_visit_summary(today)
        agent_cards = get_agent_readiness(today)
        action_items = get_dashboard_action_items(today)
        weekly = get_weekly_summary(today)
        recent_summaries = get_recent_post_call_summaries(limit=5)
        next_visit = get_next_upcoming_visit()
        todays_visits = get_visits_for_date(today)

        # Minutes until next visit for countdown
        now = timezone.now()
        next_visit_minutes = None
        if next_visit and next_visit.start_time > now:
            next_visit_minutes = int((next_visit.start_time - now).total_seconds() / 60)

        context = {
            'today': today,
            'visit_summary': visit_summary,
            'agent_cards': agent_cards,
            'action_items': action_items,
            'weekly': weekly,
            'recent_summaries': recent_summaries,
            'next_visit': next_visit,
            'next_visit_minutes': next_visit_minutes,
            'todays_visits': todays_visits,
        }

        placeholders.dashboard_extras(context)
        return render(request, 'voice/manager/dashboard.html', context)


class TestCallView(SuperuserRequiredMixin, View):
    """Test call view - allows superuser to trigger a test call to their phone."""
    
    def post(self, request):
        """Handle test call request."""
        from django.utils import timezone
        from datetime import timedelta
        from .models import Meeting, CallAttempt
        from .constants import CallPhase, CallStatus
        from .services import trigger_agent_call, format_prompt_with_context
        from .selectors import get_active_prompt
        
        phone_number = request.POST.get('phone_number', '').strip()
        
        # If no phone number provided, try to use superuser's phone number
        if not phone_number:
            phone_number = request.user.phone_number
        
        if not phone_number:
            messages.error(request, 'Please provide a phone number or set your phone number in your profile.')
            return redirect('voice:superuser_dashboard')
        
        # Validate phone number
        from .utils import validate_phone_number, format_phone_number
        if not validate_phone_number(phone_number):
            messages.error(request, 'Invalid phone number format. Please use E.164 format (e.g., +1234567890).')
            return redirect('voice:superuser_dashboard')
        
        formatted_phone = format_phone_number(phone_number)
        
        try:
            # Get active prompt (use pre-meeting as default for test)
            prompt = get_active_prompt(CallPhase.PRE_MEETING)
            if not prompt:
                messages.error(request, 'No active pre-meeting prompt found. Please create a prompt first.')
                return redirect('voice:superuser_dashboard')
            
            # Create a temporary test meeting
            test_meeting = Meeting.objects.create(
                agent=request.user,
                external_id=f'test_{timezone.now().timestamp()}',
                title='Test Call',
                customer_name='Test Customer',
                start_time=timezone.now() + timedelta(hours=1),
                end_time=timezone.now() + timedelta(hours=2),
            )
            
            # Create call attempt
            call_attempt = CallAttempt.objects.create(
                meeting=test_meeting,
                phase=CallPhase.PRE_MEETING,
                scheduled_offset_minutes=-60,  # Standard pre-meeting offset
                status=CallStatus.SCHEDULED
            )
            
            # Format prompt with meeting context
            formatted_prompt = format_prompt_with_context(prompt.system_prompt, test_meeting)
            
            # Format first_message if available
            formatted_first_message = None
            if prompt.first_message:
                formatted_first_message = format_first_message_with_context(prompt.first_message, test_meeting)
            
            # Prepare context data
            context_data = {
                'meeting_id': test_meeting.id,
                'offset_minutes': -60,
                'call_attempt_id': call_attempt.id,
                'is_test_call': True,
            }
            
            # Trigger the call
            result = trigger_agent_call(
                agent_phone=formatted_phone,
                prompt_text=formatted_prompt,
                context_data=context_data,
                call_attempt=call_attempt,
                first_message_text=formatted_first_message
            )
            
            if result['success']:
                messages.success(request, f'Test call initiated! Call ID: {result.get("call_id", "N/A")}. You should receive a call shortly.')
            else:
                error_msg = result.get('error', 'Unknown error')
                messages.error(request, f'Failed to initiate test call: {error_msg}')
                # Clean up test meeting if call failed
                test_meeting.delete()
            
        except Exception as e:
            logger.error(f"Error initiating test call: {e}", exc_info=True)
            messages.error(request, f'Error initiating test call: {str(e)}')
        
        return redirect('voice:superuser_dashboard')


class PromptListView(SuperuserRequiredMixin, View):
    """List all voice prompts grouped by type."""

    def get(self, request):
        all_prompts = VoicePrompt.objects.all().order_by('-is_active', '-created_at')
        pre_prompts = [p for p in all_prompts if p.prompt_type == 'PRE']
        post_prompts = [p for p in all_prompts if p.prompt_type == 'POST']
        active_pre = next((p for p in pre_prompts if p.is_active), None)
        active_post = next((p for p in post_prompts if p.is_active), None)

        context = {
            'pre_prompts': pre_prompts,
            'post_prompts': post_prompts,
            'active_pre': active_pre,
            'active_post': active_post,
            'total_count': all_prompts.count(),
        }
        return render(request, 'voice/manager/prompt_list.html', context)


class PromptEditView(SuperuserRequiredMixin, View):
    """Edit a voice prompt with preview."""
    
    def get(self, request, prompt_id):
        try:
            prompt = VoicePrompt.objects.get(id=prompt_id)
        except VoicePrompt.DoesNotExist:
            messages.error(request, 'Prompt not found.')
            return redirect('voice:prompt_list')
        
        # Preview with dummy data
        preview_text = prompt.system_prompt.replace('{agent_name}', 'John Doe')
        preview_text = preview_text.replace('{customer_name}', 'Acme Corporation')
        preview_text = preview_text.replace('{meeting_title}', 'Q4 Product Demo')
        
        # Preview first_message if available
        preview_first_message = None
        if prompt.first_message:
            preview_first_message = prompt.first_message.replace('{agent_name}', 'John Doe')
            preview_first_message = preview_first_message.replace('{customer_name}', 'Acme Corporation')
            preview_first_message = preview_first_message.replace('{meeting_title}', 'Q4 Product Demo')
        
        context = {
            'prompt': prompt,
            'preview_text': preview_text,
            'preview_first_message': preview_first_message,
        }
        return render(request, 'voice/manager/prompt_form.html', context)
    
    def post(self, request, prompt_id):
        try:
            prompt = VoicePrompt.objects.get(id=prompt_id)
        except VoicePrompt.DoesNotExist:
            messages.error(request, 'Prompt not found.')
            return redirect('voice:prompt_list')
        
        prompt.name = request.POST.get('name', prompt.name)
        prompt.system_prompt = request.POST.get('system_prompt', prompt.system_prompt)
        prompt.first_message = request.POST.get('first_message', '') or None
        prompt.prompt_type = request.POST.get('prompt_type', prompt.prompt_type)
        prompt.is_active = request.POST.get('is_active') == 'on'
        
        # Ensure only one active prompt per type
        if prompt.is_active:
            VoicePrompt.objects.filter(
                prompt_type=prompt.prompt_type,
                is_active=True
            ).exclude(id=prompt.id).update(is_active=False)
        
        prompt.save()
        messages.success(request, 'Prompt updated successfully.')
        return redirect('voice:prompt_list')


class AgentManagementView(SuperuserRequiredMixin, View):
    """Manage sales agents."""

    def get(self, request):
        today = timezone.now().date()
        agents = User.objects.filter(is_sales_agent=True).select_related('default_methodology').order_by('username')
        methodologies = Methodology.objects.filter(is_active=True).order_by('name')

        enriched_agents = []
        for agent in agents:
            today_visits = Visit.objects.filter(agent=agent, start_time__date=today)
            total_calls = CallAttempt.objects.filter(visit__agent=agent)
            completed_calls = total_calls.filter(status='COMPLETED').count()
            total_call_count = total_calls.count()

            # Config issues
            issues = []
            if not agent.phone_number:
                issues.append('No phone number')
            if not agent.default_methodology:
                issues.append('No methodology')
            if not agent.email:
                issues.append('No email')

            enriched_agents.append({
                'agent': agent,
                'visits_today': today_visits.count(),
                'visits_complete_today': today_visits.filter(status='COMPLETE').count(),
                'total_calls': total_call_count,
                'call_success_rate': round(completed_calls / total_call_count * 100) if total_call_count else 0,
                'has_phone': bool(agent.phone_number),
                'issues': issues,
                'is_configured': len(issues) == 0,
            })

        context = {
            'agents': enriched_agents,
            'methodologies': methodologies,
            'agent_count': agents.count(),
            'configured_count': sum(1 for a in enriched_agents if a['is_configured']),
        }
        placeholders.agents_extras(context)
        return render(request, 'voice/manager/agent_list.html', context)


class AgentDetailView(SuperuserRequiredMixin, View):
    """Read-only detail view for a single sales agent."""

    def get(self, request, agent_id):
        from django.shortcuts import get_object_or_404
        agent = get_object_or_404(User, id=agent_id, is_sales_agent=True)
        recent_visits = list(get_agent_visits(agent)[:20])
        recent_calls = list(
            CallAttempt.objects.filter(visit__agent=agent)
            .select_related('visit', 'visit__client')
            .order_by('-created_at')[:10]
        )
        context = {
            'agent': agent,
            'recent_visits': recent_visits,
            'recent_calls': recent_calls,
        }
        context.update(placeholders.agent_detail_extras(agent, recent_visits, recent_calls))
        return render(request, 'voice/manager/agent_detail.html', context)


class AgentCreateView(SuperuserRequiredMixin, View):
    """Create a new sales agent."""

    def get(self, request):
        form = AgentCreateForm()
        return render(request, 'voice/manager/agent_form.html', {'form': form})

    def post(self, request):
        form = AgentCreateForm(request.POST)
        if form.is_valid():
            agent = form.save()
            log_activity(
                action=f"Created sales agent: {agent.username}",
                user=request.user,
                level='INFO',
            )
            messages.success(request, f'Agent "{agent.username}" created successfully.')
            return redirect('voice:agent_management')
        return render(request, 'voice/manager/agent_form.html', {'form': form})


class AuditLogExplorerView(SuperuserRequiredMixin, View):
    """Filterable activity log viewer."""
    
    def get(self, request):
        level = request.GET.get('level')
        user_id = request.GET.get('user_id')
        
        # Convert user_id to int with error handling
        try:
            user_id = int(user_id) if user_id else None
        except (ValueError, TypeError):
            user_id = None
        
        logs = get_activity_logs_filtered(level=level, user_id=user_id, limit=100)
        log_count = logs.count() if hasattr(logs, 'count') else len(logs)

        context = {
            'logs': logs,
            'log_count': log_count,
            'selected_level': level or '',
            'selected_user_id': str(user_id) if user_id else '',
            'users': User.objects.filter(is_sales_agent=True).order_by('username'),
        }
        return render(request, 'voice/manager/logs.html', context)


class NgrokWebhookStatusView(SuperuserRequiredMixin, View):
    """Dashboard view showing ngrok URL and webhook configuration status."""
    
    def get(self, request):
        from decouple import config
        
        # Get ngrok URL
        ngrok_api_url = config('NGROK_API_URL', default='http://localhost:4040/api/tunnels')
        ngrok_url = get_ngrok_url(ngrok_api_url)
        
        # Build webhook URL
        webhook_url = None
        if ngrok_url:
            webhook_url = build_webhook_url(ngrok_url)
        
        # Try to get current webhook config from ElevenLabs
        webhook_config = get_elevenlabs_webhook_config()
        current_webhook_url = webhook_config.get('url') if webhook_config else None
        webhook_configured = current_webhook_url == webhook_url if (current_webhook_url and webhook_url) else False
        
        # Check if update is needed
        update_needed = ngrok_url and webhook_url and current_webhook_url != webhook_url
        
        context = {
            'ngrok_url': ngrok_url,
            'webhook_url': webhook_url,
            'current_webhook_url': current_webhook_url,
            'webhook_configured': webhook_configured,
            'update_needed': update_needed,
            'webhook_config': webhook_config,
            'ngrok_running': ngrok_url is not None,
        }
        
        return render(request, 'voice/manager/ngrok_webhook_status.html', context)
    
    def post(self, request):
        """Handle webhook URL update request."""
        from decouple import config
        
        ngrok_api_url = config('NGROK_API_URL', default='http://localhost:4040/api/tunnels')
        ngrok_url = get_ngrok_url(ngrok_api_url)
        
        if not ngrok_url:
            messages.error(request, 'Ngrok is not running. Please start ngrok first.')
            return redirect('voice:ngrok_webhook_status')
        
        webhook_url = build_webhook_url(ngrok_url)
        
        # Attempt to update webhook
        result = update_elevenlabs_webhook(webhook_url)
        
        if result.get('success'):
            messages.success(request, 'Webhook URL updated successfully in ElevenLabs!')
        else:
            error_msg = result.get('error', 'Unknown error')
            messages.warning(
                request, 
                f'Could not update webhook automatically: {error_msg}. '
                f'Please update manually in ElevenLabs dashboard. Webhook URL: {webhook_url}'
            )
        
        return redirect('voice:ngrok_webhook_status')


# ============================================================================
# Sales Agent Views
# ============================================================================

class SalesAgentDashboardView(SalesAgentRequiredMixin, View):
    """Sales agent dashboard with timeline view."""
    
    def get(self, request):
        agent = request.user
        timeline_data = get_agent_timeline_data(agent)
        upcoming_meetings = get_upcoming_meetings_for_agent(agent, limit=10)
        call_stats = get_agent_call_statistics(agent)
        
        # Calculate count for template (works with both QuerySet and list)
        upcoming_meetings_count = upcoming_meetings.count() if hasattr(upcoming_meetings, 'count') else len(upcoming_meetings)
        
        context = {
            'timeline_data': timeline_data,
            'upcoming_meetings': upcoming_meetings,
            'upcoming_meetings_count': upcoming_meetings_count,
            'call_stats': call_stats,
        }
        return render(request, 'voice/agent/dashboard.html', context)


class MeetingDetailView(LoginRequiredMixin, View):
    """Detailed meeting view with tabs for pre/post meeting calls."""
    
    def get(self, request, meeting_id):
        try:
            # Superusers can view any meeting, sales agents can only view their own
            if request.user.is_superuser:
                meeting = Meeting.objects.get(id=meeting_id)
            else:
                meeting = Meeting.objects.get(id=meeting_id, agent=request.user)
        except Meeting.DoesNotExist:
            messages.error(request, 'Meeting not found.')
            if request.user.is_superuser:
                return redirect('voice:programmed_calls')
            else:
                return redirect('voice:sales_agent_dashboard')
        
        from .selectors import get_call_attempts_for_meeting
        from .constants import CallPhase
        
        pre_calls = get_call_attempts_for_meeting(meeting, phase=CallPhase.PRE_MEETING)
        post_calls = get_call_attempts_for_meeting(meeting, phase=CallPhase.POST_MEETING)
        
        context = {
            'meeting': meeting,
            'pre_calls': pre_calls,
            'post_calls': post_calls,
        }
        return render(request, 'voice/agent/meeting_detail.html', context)


class SalesAgentProfileView(SalesAgentRequiredMixin, View):
    """Sales agent profile settings."""
    
    def get(self, request):
        context = {
            'user': request.user,
        }
        return render(request, 'voice/agent/profile.html', context)
    
    def post(self, request):
        user = request.user
        phone_number = request.POST.get('phone_number', '').strip()
        
        if phone_number:
            from .utils import validate_phone_number, format_phone_number
            try:
                if validate_phone_number(phone_number):
                    user.phone_number = format_phone_number(phone_number)
                    user.save()
                    messages.success(request, 'Phone number updated successfully.')
                else:
                    messages.error(request, 'Invalid phone number format. Please use E.164 format (e.g., +1234567890).')
            except Exception as e:
                messages.error(request, f'Error updating phone number: {str(e)}')
        else:
            try:
                user.phone_number = None
                user.save()
                messages.success(request, 'Phone number cleared.')
            except Exception as e:
                messages.error(request, f'Error clearing phone number: {str(e)}')
        
        return redirect('voice:sales_agent_profile')


class ProgrammedCallsView(SuperuserRequiredMixin, View):
    """View all programmed/scheduled calls for superuser."""
    
    def get(self, request):
        from .constants import PRE_MEETING_OFFSETS, POST_MEETING_OFFSETS
        from .selectors import get_meetings_for_pre_call_check, get_meetings_for_post_call_check
        from .services import should_trigger_pre_call, should_trigger_post_call
        
        # Get filter parameters
        status_filter = request.GET.get('status', '')
        phase_filter = request.GET.get('phase', '')
        agent_filter = request.GET.get('agent', '')
        show_upcoming = request.GET.get('show_upcoming', 'true') == 'true'
        
        # Base queryset for actual CallAttempt records
        calls = CallAttempt.objects.select_related(
            'meeting', 'meeting__agent', 'visit', 'visit__agent', 'visit__client',
        ).all()

        # Apply filters
        if status_filter:
            calls = calls.filter(status=status_filter)
        if phase_filter:
            calls = calls.filter(phase=phase_filter)
        if agent_filter:
            from django.db.models import Q
            calls = calls.filter(Q(meeting__agent_id=agent_filter) | Q(visit__agent_id=agent_filter))

        # Order by created_at (newest first)
        calls = calls.order_by('-created_at')

        # Calculate scheduled call time for actual calls
        for call in calls:
            # Resolve times from visit or meeting
            if call.visit:
                start = call.visit.start_time
                end = call.visit.end_time
                call._agent = call.visit.agent
                call._title = call.visit.title
            elif call.meeting:
                start = call.meeting.start_time
                end = call.meeting.end_time
                call._agent = call.meeting.agent
                call._title = call.meeting.title
            else:
                continue
            if call.phase == 'PRE':
                call.scheduled_time = start + timedelta(minutes=call.scheduled_offset_minutes)
            else:
                call.scheduled_time = end + timedelta(minutes=call.scheduled_offset_minutes)
        
        # Get upcoming scheduled calls (not yet triggered)
        upcoming_calls = []
        if show_upcoming:
            # Get meetings that need pre-meeting calls
            pre_meetings = get_meetings_for_pre_call_check()
            for meeting, offset in pre_meetings:
                if should_trigger_pre_call(meeting, offset):
                    # Apply filters
                    if agent_filter and str(meeting.agent_id) != agent_filter:
                        continue
                    if phase_filter and phase_filter != 'PRE':
                        continue
                    
                    # Create a virtual call object
                    virtual_call = type('VirtualCall', (), {
                        'id': None,
                        'meeting': meeting,
                        'phase': 'PRE',
                        'scheduled_offset_minutes': offset,
                        'status': 'SCHEDULED',
                        'external_call_id': None,
                        'recording_url': None,
                        'transcript': None,
                        'summary': None,
                        'summary_title': None,
                        'executed_at': None,
                        'created_at': None,
                        'scheduled_time': meeting.start_time + timedelta(minutes=offset),
                        'is_upcoming': True,
                    })()
                    upcoming_calls.append(virtual_call)
            
            # Get meetings that need post-meeting calls
            post_meetings = get_meetings_for_post_call_check()
            for meeting, offset in post_meetings:
                if should_trigger_post_call(meeting, offset):
                    # Apply filters
                    if agent_filter and str(meeting.agent_id) != agent_filter:
                        continue
                    if phase_filter and phase_filter != 'POST':
                        continue
                    
                    # Create a virtual call object
                    virtual_call = type('VirtualCall', (), {
                        'id': None,
                        'meeting': meeting,
                        'phase': 'POST',
                        'scheduled_offset_minutes': offset,
                        'status': 'SCHEDULED',
                        'external_call_id': None,
                        'recording_url': None,
                        'transcript': None,
                        'summary': None,
                        'summary_title': None,
                        'executed_at': None,
                        'created_at': None,
                        'scheduled_time': meeting.end_time + timedelta(minutes=offset),
                        'is_upcoming': True,
                    })()
                    upcoming_calls.append(virtual_call)
            
            # Sort upcoming calls by scheduled_time
            upcoming_calls.sort(key=lambda x: x.scheduled_time if x.scheduled_time else timezone.now())
        
        # Combine actual calls and upcoming calls
        all_calls = list(calls) + upcoming_calls
        now = timezone.now()
        
        # Add helper flags for template rendering
        for call in all_calls:
            # Resolve start/end from visit or meeting
            if hasattr(call, 'is_upcoming') and call.is_upcoming:
                _start = call.meeting.start_time
                _end = call.meeting.end_time
            elif hasattr(call, 'visit') and call.visit:
                _start = call.visit.start_time
                _end = call.visit.end_time
            elif hasattr(call, 'meeting') and call.meeting:
                _start = call.meeting.start_time
                _end = call.meeting.end_time
            else:
                call.can_retry = False
                call.can_trigger = False
                continue

            if hasattr(call, 'is_upcoming') and call.is_upcoming:
                if call.phase == 'PRE':
                    call.can_trigger = _start > now
                else:
                    call.can_trigger = _end < now
            elif call.status == 'FAILED':
                if call.phase == 'PRE':
                    call.can_retry = _start > now
                else:
                    call.can_retry = _end < now
            elif call.status == 'SCHEDULED':
                if call.phase == 'PRE':
                    call.can_trigger = _start > now
                else:
                    call.can_trigger = _end < now
            else:
                call.can_retry = False
                call.can_trigger = False
        
        # Sort by scheduled_time (most recent first) or created_at
        def get_sort_key(x):
            if hasattr(x, 'scheduled_time') and x.scheduled_time:
                return x.scheduled_time
            elif hasattr(x, 'created_at') and x.created_at:
                return x.created_at
            else:
                return timezone.now()
        all_calls.sort(key=get_sort_key, reverse=True)
        
        # Get all agents for filter dropdown
        agents = User.objects.filter(is_sales_agent=True).order_by('username')
        
        # Get statistics (only for actual calls)
        total_calls = CallAttempt.objects.count()
        scheduled_calls = CallAttempt.objects.filter(status='SCHEDULED').count()
        in_progress_calls = CallAttempt.objects.filter(status='IN_PROGRESS').count()
        completed_calls = CallAttempt.objects.filter(status='COMPLETED').count()
        failed_calls = CallAttempt.objects.filter(status__in=['NO_ANSWER', 'FAILED']).count()
        
        context = {
            'calls': all_calls,
            'upcoming_count': len(upcoming_calls),
            'actual_count': calls.count(),
            'agents': agents,
            'status_filter': status_filter,
            'phase_filter': phase_filter,
            'agent_filter': agent_filter,
            'show_upcoming': show_upcoming,
            'now': timezone.now(),  # Pass current time to template for validation
            'stats': {
                'total': total_calls,
                'scheduled': scheduled_calls,
                'in_progress': in_progress_calls,
                'completed': completed_calls,
                'failed': failed_calls,
            }
        }
        
        return render(request, 'voice/manager/programmed_calls.html', context)


class ManualCallTriggerView(SuperuserRequiredMixin, View):
    """Manually trigger a call for a meeting."""
    
    def post(self, request):
        from .tasks import trigger_pre_meeting_call, trigger_post_meeting_call
        from .constants import PRE_MEETING_OFFSETS, POST_MEETING_OFFSETS, CallPhase
        
        meeting_id = request.POST.get('meeting_id')
        phase = request.POST.get('phase')  # 'PRE' or 'POST'
        offset_minutes = request.POST.get('offset_minutes')
        
        if not meeting_id or not phase or not offset_minutes:
            messages.error(request, 'Missing required parameters')
            return redirect('voice:programmed_calls')
        
        try:
            meeting = Meeting.objects.get(id=meeting_id)
            offset = int(offset_minutes)
            now = timezone.now()
            
            # Validation based on phase
            if phase == 'PRE':
                # Pre-meeting: only allow if current time is before meeting start
                if now >= meeting.start_time:
                    messages.error(
                        request, 
                        f'Cannot trigger pre-meeting call: Meeting has already started (started at {meeting.start_time.strftime("%Y-%m-%d %H:%M")})'
                    )
                    return redirect('voice:programmed_calls')
                
                # Validate offset is in allowed pre-meeting offsets
                if offset not in PRE_MEETING_OFFSETS:
                    messages.error(request, f'Invalid pre-meeting offset: {offset}. Allowed: {PRE_MEETING_OFFSETS}')
                    return redirect('voice:programmed_calls')
                
                # Trigger pre-meeting call
                result = trigger_pre_meeting_call(meeting_id, offset)
                
            elif phase == 'POST':
                # Post-meeting: only allow if current time is after meeting end
                if now < meeting.end_time:
                    messages.error(
                        request,
                        f'Cannot trigger post-meeting call: Meeting has not ended yet (ends at {meeting.end_time.strftime("%Y-%m-%d %H:%M")})'
                    )
                    return redirect('voice:programmed_calls')
                
                # Validate offset is in allowed post-meeting offsets
                if offset not in POST_MEETING_OFFSETS:
                    messages.error(request, f'Invalid post-meeting offset: {offset}. Allowed: {POST_MEETING_OFFSETS}')
                    return redirect('voice:programmed_calls')
                
                # Trigger post-meeting call
                result = trigger_post_meeting_call(meeting_id, offset)
            else:
                messages.error(request, f'Invalid phase: {phase}')
                return redirect('voice:programmed_calls')
            
            if result.get('success'):
                messages.success(request, f'Call triggered successfully! Call ID: {result.get("call_id", "N/A")}')
            else:
                error_msg = result.get('error', 'Unknown error')
                messages.error(request, f'Failed to trigger call: {error_msg}')
        
        except Meeting.DoesNotExist:
            messages.error(request, 'Meeting not found')
        except ValueError:
            messages.error(request, 'Invalid offset value')
        except Exception as e:
            logger.error(f"Error in manual call trigger: {e}", exc_info=True)
            messages.error(request, f'Error triggering call: {str(e)}')

        return redirect('voice:programmed_calls')


# ============================================================================
# Methodology Views
# ============================================================================

class MethodologyListView(SuperuserRequiredMixin, View):
    """List all methodologies with usage stats."""

    def get(self, request):
        methodologies = Methodology.objects.all().select_related('created_by').order_by('-is_active', 'name')
        settings = GlobalSettings.load()
        system_default_id = settings.default_methodology_id

        enriched = []
        for m in methodologies:
            agents_using = User.objects.filter(
                is_sales_agent=True, default_methodology=m
            ).count()
            visits_using = Visit.objects.filter(methodology=m).count()

            enriched.append({
                'methodology': m,
                'agents_using': agents_using,
                'visits_using': visits_using,
                'is_system_default': m.id == system_default_id,
                'has_pdf': bool(m.source_material),
                'has_summary': bool(m.ai_summary),
            })

        active_count = sum(1 for e in enriched if e['methodology'].is_active)

        context = {
            'methodologies': enriched,
            'total_count': len(enriched),
            'active_count': active_count,
        }
        placeholders.methodologies_extras(context)
        return render(request, 'voice/manager/methodology_list.html', context)


class MethodologyCreateView(SuperuserRequiredMixin, View):
    """Create a new methodology with optional PDF upload."""

    def get(self, request):
        form = MethodologyForm()
        return render(request, 'voice/manager/methodology_form.html', {'form': form})

    def post(self, request):
        form = MethodologyForm(request.POST, request.FILES)
        if form.is_valid():
            methodology = form.save(commit=False)
            methodology.created_by = request.user
            methodology.save()

            # Process PDF if uploaded
            if methodology.source_material:
                try:
                    from .services.llm import extract_pdf_text, summarize_methodology_pdf, is_configured
                    if is_configured():
                        pdf_text = extract_pdf_text(methodology.source_material.path)
                        if pdf_text:
                            summary = summarize_methodology_pdf(pdf_text)
                            if summary:
                                methodology.ai_summary = summary
                                methodology.save(update_fields=['ai_summary'])
                                messages.success(request, f'Methodology "{methodology.name}" created with AI summary.')
                            else:
                                messages.warning(request, f'Methodology created but AI summary generation failed. You can add it manually.')
                        else:
                            messages.warning(request, f'Methodology created but PDF text extraction failed.')
                    else:
                        messages.info(request, f'Methodology created. Configure ANTHROPIC_API_KEY to enable AI summarization.')
                except Exception as e:
                    logger.error(f"Error processing methodology PDF: {e}", exc_info=True)
                    messages.warning(request, f'Methodology created but PDF processing failed: {e}')
            else:
                messages.success(request, f'Methodology "{methodology.name}" created.')

            return redirect('voice:methodology_list')
        return render(request, 'voice/manager/methodology_form.html', {'form': form})


class MethodologyEditView(SuperuserRequiredMixin, View):
    """Edit an existing methodology."""

    def get(self, request, methodology_id):
        try:
            methodology = Methodology.objects.get(id=methodology_id)
        except Methodology.DoesNotExist:
            messages.error(request, 'Methodology not found.')
            return redirect('voice:methodology_list')
        form = MethodologyForm(instance=methodology)
        return render(request, 'voice/manager/methodology_form.html', {
            'form': form,
            'methodology': methodology,
            'editing': True,
        })

    def post(self, request, methodology_id):
        try:
            methodology = Methodology.objects.get(id=methodology_id)
        except Methodology.DoesNotExist:
            messages.error(request, 'Methodology not found.')
            return redirect('voice:methodology_list')

        form = MethodologyForm(request.POST, request.FILES, instance=methodology)
        if form.is_valid():
            methodology = form.save()

            # Re-process PDF if a new one was uploaded
            if 'source_material' in request.FILES:
                try:
                    from .services.llm import extract_pdf_text, summarize_methodology_pdf, is_configured
                    if is_configured():
                        pdf_text = extract_pdf_text(methodology.source_material.path)
                        if pdf_text:
                            summary = summarize_methodology_pdf(pdf_text)
                            if summary:
                                methodology.ai_summary = summary
                                methodology.save(update_fields=['ai_summary'])
                                messages.success(request, 'Methodology updated with new AI summary.')
                                return redirect('voice:methodology_list')
                except Exception as e:
                    logger.error(f"Error processing methodology PDF: {e}", exc_info=True)
                    messages.warning(request, f'Methodology updated but PDF processing failed: {e}')

            messages.success(request, f'Methodology "{methodology.name}" updated.')
            return redirect('voice:methodology_list')
        return render(request, 'voice/manager/methodology_form.html', {
            'form': form,
            'methodology': methodology,
            'editing': True,
        })


# ============================================================================
# Global Settings View
# ============================================================================

class GlobalSettingsView(SuperuserRequiredMixin, View):
    """Edit global system settings."""

    def get(self, request):
        settings_obj = GlobalSettings.load()
        form = GlobalSettingsForm(instance=settings_obj)
        return render(request, 'voice/manager/settings.html', {'form': form})

    def post(self, request):
        settings_obj = GlobalSettings.load()
        form = GlobalSettingsForm(request.POST, instance=settings_obj)
        if form.is_valid():
            form.save()
            messages.success(request, 'Settings updated.')
            return redirect('voice:global_settings')
        return render(request, 'voice/manager/settings.html', {'form': form})


# ============================================================================
# Visit Management Views
# ============================================================================

class VisitListView(SuperuserRequiredMixin, View):
    """List all visits for today or a selected date, across all agents."""

    def get(self, request):
        date_str = request.GET.get('date')
        agent_id = request.GET.get('agent')
        status_filter = request.GET.get('status')
        # Named filter group from the top pills: all | upcoming | completed | cancelled
        group_filter = (request.GET.get('filter') or 'all').lower()

        if date_str:
            try:
                target_date = datetime.strptime(date_str, '%Y-%m-%d').date()
            except ValueError:
                target_date = timezone.now().date()
        else:
            target_date = timezone.now().date()

        agent = None
        if agent_id:
            try:
                agent = User.objects.get(id=agent_id, is_sales_agent=True)
            except User.DoesNotExist:
                pass

        from .constants import VisitStatus
        visits = get_visits_for_date(target_date, agent=agent)
        # Top-pill group filter takes precedence; falls back to the exact-status
        # dropdown if no group is active.
        if group_filter == 'upcoming':
            visits = visits.exclude(status=VisitStatus.COMPLETE)
        elif group_filter == 'completed':
            visits = visits.filter(status=VisitStatus.COMPLETE)
        elif group_filter == 'cancelled':
            # No CANCELLED status in the enum yet — yields an empty list honestly.
            visits = visits.filter(status='CANCELLED')
        elif status_filter:
            visits = visits.filter(status=status_filter)

        # Enrich visits with call counts for display
        enriched_visits = []
        for visit in visits:
            pre = CallAttempt.objects.filter(visit=visit, phase='PRE')
            post = CallAttempt.objects.filter(visit=visit, phase='POST')
            enriched_visits.append({
                'visit': visit,
                'pre_call_count': pre.count(),
                'pre_call_done': pre.filter(status='COMPLETED').exists(),
                'post_call_count': post.count(),
                'post_call_done': post.filter(status='COMPLETED').exists(),
                'has_failed_call': pre.filter(status__in=['FAILED', 'NO_ANSWER']).exists()
                    or post.filter(status__in=['FAILED', 'NO_ANSWER']).exists(),
            })

        # Status summary for the strip
        summary = get_dashboard_visit_summary(target_date)

        # Date navigation
        prev_date = target_date - timedelta(days=1)
        next_date = target_date + timedelta(days=1)
        is_today = target_date == timezone.now().date()

        agents = User.objects.filter(is_sales_agent=True).order_by('username')

        from .constants import VisitStatus
        context = {
            'visits': enriched_visits,
            'target_date': target_date,
            'prev_date': prev_date,
            'next_date': next_date,
            'is_today': is_today,
            'summary': summary,
            'agents': agents,
            'agent_filter': agent_id or '',
            'status_filter': status_filter or '',
            'group_filter': group_filter,
            'status_choices': VisitStatus.choices,
            'now': timezone.now(),
        }
        placeholders.visits_extras(context)
        return render(request, 'voice/manager/visit_list.html', context)


class VisitDetailView(SuperuserRequiredMixin, View):
    """View and edit a single visit — manager notes, methodology override, call status."""

    def _build_context(self, visit, form):
        pre_calls = CallAttempt.objects.filter(visit=visit, phase='PRE').order_by('created_at')
        post_calls = CallAttempt.objects.filter(visit=visit, phase='POST').order_by('created_at')

        # Progress steps for the tracker
        from .constants import VisitStatus
        status_order = [
            VisitStatus.PLANNED, VisitStatus.PRE_CALL_DONE,
            VisitStatus.IN_PROGRESS, VisitStatus.POST_CALL_DONE, VisitStatus.COMPLETE,
        ]
        current_idx = status_order.index(visit.status) if visit.status in status_order else 0
        steps = [
            {'key': 'planned', 'label': 'Planned', 'done': current_idx >= 0, 'active': current_idx == 0},
            {'key': 'pre_call', 'label': 'Pre-Call', 'done': current_idx >= 1, 'active': current_idx == 1},
            {'key': 'meeting', 'label': 'Meeting', 'done': current_idx >= 2, 'active': current_idx == 2},
            {'key': 'post_call', 'label': 'Post-Call', 'done': current_idx >= 3, 'active': current_idx == 3},
            {'key': 'complete', 'label': 'Complete', 'done': current_idx >= 4, 'active': current_idx == 4},
        ]

        # Pre-call status summary
        pre_call_status = 'pending'
        if pre_calls.filter(status='COMPLETED').exists():
            pre_call_status = 'done'
        elif pre_calls.filter(status__in=['FAILED', 'NO_ANSWER']).exists():
            pre_call_status = 'failed'
        elif pre_calls.filter(status__in=['INITIATED', 'IN_PROGRESS']).exists():
            pre_call_status = 'active'

        post_call_status = 'pending'
        if post_calls.filter(status='COMPLETED').exists():
            post_call_status = 'done'
        elif post_calls.filter(status__in=['FAILED', 'NO_ANSWER']).exists():
            post_call_status = 'failed'
        elif post_calls.filter(status__in=['INITIATED', 'IN_PROGRESS']).exists():
            post_call_status = 'active'

        effective_methodology = visit.get_effective_methodology()
        context = {
            'visit': visit,
            'form': form,
            'pre_calls': pre_calls,
            'post_calls': post_calls,
            'effective_methodology': effective_methodology,
            'steps': steps,
            'pre_call_status': pre_call_status,
            'post_call_status': post_call_status,
        }
        context.update(placeholders.visit_detail_extras(
            visit, pre_calls, post_calls, effective_methodology
        ))
        return context

    def get(self, request, visit_id):
        try:
            visit = Visit.objects.select_related(
                'agent', 'client', 'methodology', 'agent__default_methodology',
            ).get(id=visit_id)
        except Visit.DoesNotExist:
            messages.error(request, 'Visit not found.')
            return redirect('voice:visit_list')

        form = VisitManagerNotesForm(instance=visit)
        context = self._build_context(visit, form)
        return render(request, 'voice/manager/visit_detail.html', context)

    def post(self, request, visit_id):
        try:
            visit = Visit.objects.select_related(
                'agent', 'client', 'methodology', 'agent__default_methodology',
            ).get(id=visit_id)
        except Visit.DoesNotExist:
            messages.error(request, 'Visit not found.')
            return redirect('voice:visit_list')

        form = VisitManagerNotesForm(request.POST, instance=visit)
        if form.is_valid():
            form.save()
            log_activity(
                user=request.user,
                action=f"Manager updated visit: {visit.title}",
                details={'visit_id': visit.id},
            )
            messages.success(request, 'Visit updated.')
            return redirect('voice:visit_detail', visit_id=visit.id)

        context = self._build_context(visit, form)
        return render(request, 'voice/manager/visit_detail.html', context)


class VisitCallNowView(SuperuserRequiredMixin, View):
    """Trigger an EL outbound call for a Visit's pre or post phase."""

    def post(self, request, visit_id, phase):
        from django.shortcuts import get_object_or_404
        from voice.services.elevenlabs import trigger_visit_call

        visit = get_object_or_404(Visit, id=visit_id)
        if phase not in ('pre', 'post'):
            messages.error(request, "Invalid call phase.")
            return redirect('voice:visit_detail', visit_id=visit_id)

        result = trigger_visit_call(visit, phase)
        if result['success']:
            messages.success(
                request,
                f"{phase.title()}-call initiated for {visit.client.name if visit.client else 'visit'}. "
                f"Call ID: {result['call_id']}"
            )
        else:
            messages.error(request, f"Call failed: {result['error']}")
        return redirect('voice:visit_detail', visit_id=visit_id)


class VisitStatusUpdateView(SuperuserRequiredMixin, View):
    """Manually advance Visit.status (used by the 'Marchează întâlnirea...' buttons)."""

    def post(self, request, visit_id, status):
        from django.shortcuts import get_object_or_404
        from .constants import VisitStatus

        visit = get_object_or_404(Visit, id=visit_id)
        valid_values = {choice[0] for choice in VisitStatus.choices}
        if status not in valid_values:
            messages.error(request, f"Status invalid: {status}")
            return redirect('voice:visit_detail', visit_id=visit_id)

        visit.status = status
        visit.save(update_fields=['status', 'updated_at'])
        messages.success(
            request,
            f"Vizita {visit.client.name if visit.client else ''} a fost marcată ca "
            f"{dict(VisitStatus.choices).get(status, status)}."
        )
        return redirect('voice:visit_detail', visit_id=visit_id)


class AgentMethodologyView(SuperuserRequiredMixin, View):
    """Assign default methodology to an agent."""

    def post(self, request, agent_id):
        try:
            agent = User.objects.get(id=agent_id, is_sales_agent=True)
        except User.DoesNotExist:
            messages.error(request, 'Agent not found.')
            return redirect('voice:agent_management')

        form = AgentMethodologyForm(request.POST, instance=agent)
        if form.is_valid():
            form.save()
            methodology = agent.default_methodology
            msg = f'Default methodology for {agent.username} set to "{methodology.name}".' if methodology else f'Default methodology cleared for {agent.username}.'
            messages.success(request, msg)
        return redirect('voice:agent_management')


# ============================================================================
# Client Views
# ============================================================================

class ClientListView(SuperuserRequiredMixin, View):
    """Browse all CRM-synced clients."""

    def get(self, request):
        search = request.GET.get('q', '').strip()
        clients = get_clients_with_stats()

        if search:
            clients = [
                c for c in clients
                if search.lower() in c['client'].name.lower()
                or (c['client'].industry and search.lower() in c['client'].industry.lower())
                or (c['client'].domain and search.lower() in c['client'].domain.lower())
            ]

        total_count = Client.objects.count()
        with_summary = Client.objects.filter(ai_summary__isnull=False).exclude(ai_summary='').count()

        context = {
            'clients': clients,
            'search': search,
            'total_count': total_count,
            'with_summary': with_summary,
        }
        placeholders.clients_extras(context)
        return render(request, 'voice/manager/client_list.html', context)


class ClientDetailView(SuperuserRequiredMixin, View):
    """View a single client's full profile, visits, and call history."""

    def get(self, request, client_id):
        context = get_client_detail(client_id)
        if context is None:
            messages.error(request, 'Client not found.')
            return redirect('voice:client_list')

        context.update(placeholders.client_detail_extras(context))
        return render(request, 'voice/manager/client_detail.html', context)


class ClientCreateView(SuperuserRequiredMixin, View):
    """Create a new client manually."""

    def get(self, request):
        form = ClientForm()
        return render(request, 'voice/manager/client_form.html', {'form': form})

    def post(self, request):
        form = ClientForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, f'Client "{form.instance.name}" created.')
            return redirect('voice:client_detail', client_id=form.instance.id)
        return render(request, 'voice/manager/client_form.html', {'form': form})


class ClientEditView(SuperuserRequiredMixin, View):
    """Edit an existing client."""

    def get(self, request, client_id):
        try:
            client = Client.objects.get(id=client_id)
        except Client.DoesNotExist:
            messages.error(request, 'Client not found.')
            return redirect('voice:client_list')
        form = ClientForm(instance=client)
        return render(request, 'voice/manager/client_form.html', {
            'form': form, 'client': client, 'editing': True,
        })

    def post(self, request, client_id):
        try:
            client = Client.objects.get(id=client_id)
        except Client.DoesNotExist:
            messages.error(request, 'Client not found.')
            return redirect('voice:client_list')
        form = ClientForm(request.POST, instance=client)
        if form.is_valid():
            form.save()
            messages.success(request, f'Client "{client.name}" updated.')
            return redirect('voice:client_detail', client_id=client.id)
        return render(request, 'voice/manager/client_form.html', {
            'form': form, 'client': client, 'editing': True,
        })


class ClientDeleteView(SuperuserRequiredMixin, View):
    """Delete a client."""

    def post(self, request, client_id):
        try:
            client = Client.objects.get(id=client_id)
        except Client.DoesNotExist:
            messages.error(request, 'Client not found.')
            return redirect('voice:client_list')
        name = client.name
        client.delete()
        messages.success(request, f'Client "{name}" deleted.')
        return redirect('voice:client_list')


# ============================================================================
# Live Agent Chat
# ============================================================================

class LiveAgentView(SuperuserRequiredMixin, View):
    """Live Agent chat page — conversational data assistant."""

    def get(self, request):
        from .services.llm import is_configured
        context = {
            'llm_configured': is_configured(),
        }
        return render(request, 'voice/manager/live_agent.html', context)


class LiveAgentChatAPI(SuperuserRequiredMixin, View):
    """AJAX endpoint for Live Agent chat messages."""

    def post(self, request):
        import json
        from django.http import JsonResponse
        from .services.llm import chat_with_data, is_configured
        from .services.data_context import assemble_data_context

        try:
            body = json.loads(request.body)
        except (json.JSONDecodeError, AttributeError):
            return JsonResponse({'error': 'Invalid request'}, status=400)

        # Handle clear chat
        if body.get('clear'):
            request.session.pop('live_agent_history', None)
            request.session.modified = True
            return JsonResponse({'status': 'cleared'})

        if not is_configured():
            return JsonResponse({
                'error': 'ANTHROPIC_API_KEY not configured'
            }, status=503)

        user_message = body.get('message', '').strip()
        if not user_message:
            return JsonResponse({'error': 'Empty message'}, status=400)

        # Get or init session conversation history
        if 'live_agent_history' not in request.session:
            request.session['live_agent_history'] = []

        history = request.session['live_agent_history']

        # Add user message
        history.append({'role': 'user', 'content': user_message})

        # Assemble fresh data context
        data_context = assemble_data_context()

        # Call Claude with full conversation
        response_text = chat_with_data(history, data_context)

        if response_text is None:
            history.pop()
            request.session.modified = True
            return JsonResponse({
                'error': 'Failed to get response from AI'
            }, status=500)

        # Add assistant response
        history.append({'role': 'assistant', 'content': response_text})

        # Keep history manageable (last 20 messages)
        if len(history) > 20:
            history = history[-20:]

        request.session['live_agent_history'] = history
        request.session.modified = True

        return JsonResponse({'response': response_text})


# ============================================================================
# Visit Calendar View
# ============================================================================

class VisitCalendarView(SuperuserRequiredMixin, View):
    """Weekly/monthly calendar view of all visits."""

    def get(self, request):
        from .selectors import get_visits_for_range
        from .constants import VisitStatus
        import calendar as cal_mod

        view_mode = request.GET.get('view', 'week')
        agent_id = request.GET.get('agent', '')
        date_str = request.GET.get('date', '')

        if view_mode == 'month':
            # Old bookmark — redirect to week
            target_iso = request.GET.get('date') or ''
            return redirect(f"{request.path}?view=week&date={target_iso}")
        if view_mode not in ('week', 'day'):
            view_mode = 'week'

        status_filter = request.GET.get('filter', 'all')
        if status_filter not in ('all', 'upcoming', 'completed', 'cancelled'):
            status_filter = 'all'

        if date_str:
            try:
                target_date = datetime.strptime(date_str, '%Y-%m-%d').date()
            except ValueError:
                target_date = timezone.now().date()
        else:
            target_date = timezone.now().date()

        agent = None
        if agent_id:
            try:
                agent = User.objects.get(id=agent_id, is_sales_agent=True)
            except User.DoesNotExist:
                pass

        if view_mode == 'day':
            visits_for_day = list(get_visits_for_range(target_date, target_date, agent=agent))
            prev_date = (target_date - timedelta(days=1)).strftime('%Y-%m-%d')
            next_date = (target_date + timedelta(days=1)).strftime('%Y-%m-%d')
            title = target_date.strftime('%A, %B %d, %Y')
            weeks = []
            visits = get_visits_for_range(target_date, target_date, agent=agent)
        else:  # week (default)
            start_date = target_date - timedelta(days=target_date.weekday())
            end_date = start_date + timedelta(days=6)
            prev_date = (start_date - timedelta(days=7)).strftime('%Y-%m-%d')
            next_date = (start_date + timedelta(days=7)).strftime('%Y-%m-%d')
            title = f"{start_date.strftime('%b %d')} - {end_date.strftime('%b %d, %Y')}"
            visits = get_visits_for_range(start_date, end_date, agent=agent)

            visits_by_date = {}
            for v in visits:
                day = v.start_time.date()
                visits_by_date.setdefault(day, []).append(v)

            weeks = []
            current = start_date
            while current <= end_date:
                week = []
                for _ in range(7):
                    week.append({
                        'date': current,
                        'visits': visits_by_date.get(current, []),
                        'is_today': current == timezone.now().date(),
                        'is_current_month': current.month == target_date.month,
                    })
                    current += timedelta(days=1)
                weeks.append(week)
            visits_for_day = []

        agents = User.objects.filter(is_sales_agent=True).order_by('username')

        # Period summary stats
        total_visits = visits.count()
        from .constants import VisitStatus
        complete_count = visits.filter(status=VisitStatus.COMPLETE).count()
        planned_count = visits.filter(status=VisitStatus.PLANNED).count()

        # Per-agent visit counts for this period
        agent_colors = ['bg-teal-500', 'bg-indigo-500', 'bg-amber-500', 'bg-rose-500', 'bg-violet-500', 'bg-cyan-500', 'bg-lime-500', 'bg-orange-500']
        agent_text_colors = ['text-teal-700', 'text-indigo-700', 'text-amber-700', 'text-rose-700', 'text-violet-700', 'text-cyan-700', 'text-lime-700', 'text-orange-700']
        agent_bg_colors = ['bg-teal-100', 'text-teal-800', 'bg-indigo-100', 'text-indigo-800', 'bg-amber-100', 'text-amber-800', 'bg-rose-100', 'text-rose-800', 'bg-violet-100', 'text-violet-800', 'bg-cyan-100', 'text-cyan-800']
        agent_color_map = {}
        for i, a in enumerate(agents):
            color_idx = i % len(agent_colors)
            agent_color_map[a.id] = {
                'dot': agent_colors[color_idx],
                'text': agent_text_colors[color_idx],
            }

        context = {
            'weeks': weeks,
            'visits_for_day': visits_for_day,
            'view_mode': view_mode,
            'target_date': target_date,
            'title': title,
            'prev_date': prev_date,
            'next_date': next_date,
            'agents': agents,
            'agent_filter': agent_id,
            'today': timezone.now().date(),
            'total_visits': total_visits,
            'complete_count': complete_count,
            'planned_count': planned_count,
            'agent_color_map': agent_color_map,
            'status_filter': status_filter,
        }
        placeholders.calendar_extras(context)
        return render(request, 'voice/manager/visit_calendar.html', context)
