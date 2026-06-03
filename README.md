# MES Voice - Sales Training & Debrief Application

[![CI](https://github.com/neurony/florina/actions/workflows/ci.yml/badge.svg)](https://github.com/neurony/florina/actions/workflows/ci.yml)

A Django-based sales enablement tool that automates voice coaching for sales agents. The system syncs meetings from Google Calendar, triggers AI-powered voice calls before and after meetings, and syncs call summaries to Pipedrive CRM.

## Project Overview

**MES Voice** automates voice coaching for sales agents through an intelligent scheduling system:

- **Trigger:** Syncs meetings from Google Calendar (with real-time push notifications)
- **Pre-Meeting (Training):** Calls the agent 1 hour before a meeting. If no answer, retries 30 mins before, then every 5 minutes until meeting starts
- **Post-Meeting (Debrief):** Calls the agent 15 mins after a meeting. If no answer, retries 30 mins after, then every 5 minutes
- **Voice Agent:** Uses ElevenLabs Conversational AI (with Twilio number configured in ElevenLabs)
- **Data Handling:** Transcripts and AI-generated summaries are saved and pushed to Pipedrive deals
- **Audit:** Every system action, API call, and retry attempt is logged immutably

## Technology Stack

- **Backend:** Django 4.2+
- **Async/Tasks:** django-apscheduler (for scheduling calls - no Redis needed!)
- **Database:** SQLite (Dev) / PostgreSQL (Prod)
- **Frontend:** Tailwind CSS + DaisyUI (via CDN)
- **Voice/AI:** ElevenLabs Conversational AI (Twilio number configured in ElevenLabs dashboard)
- **CRM:** Pipedrive API (with domain-based deal search)
- **Calendar:** Google Calendar API (OAuth 2.0 with push notifications)
- **Environment Management:** python-decouple
- **Authentication:** Django's built-in authentication system

## Project Architecture

The project follows a clean architecture pattern with clear separation of concerns:

### Application Structure

```
voice/
├── models.py          # Data Models (Users, Meetings, Prompts, Logs, OAuth Credentials, Calendar Watches)
├── views.py           # UI Views (Dashboard, Login, Calendar Sync, Programmed Calls)
├── webhook_views.py   # External Webhooks (ElevenLabs, Twilio, Google Calendar)
├── urls.py            # URL routing
├── admin.py           # Django admin configuration
├── selectors.py       # Read-only queries (Get meeting, Get active prompt, Timeline data)
├── services/          # Business Logic (Modular Package)
│   ├── __init__.py    # Re-exports all functions for backward compatibility
│   ├── logging.py     # Activity logging service
│   ├── pipedrive.py   # Pipedrive CRM integration (domain-based deal search & sync)
│   ├── elevenlabs.py  # ElevenLabs AI (call triggering, webhooks, API polling)
│   ├── google_calendar.py  # Google Calendar OAuth & sync (push notifications)
│   └── scheduler.py   # Call pre-programming & scheduling logic
├── tasks.py           # Scheduled Tasks (Entry points for scheduler)
├── decorators.py      # RBAC decorators
├── constants.py       # Magic numbers and configuration
├── utils.py           # Utility functions (phone validation, ngrok detection, timezone handling)
├── templatetags/      # Custom template tags
│   └── voice_tags.py  # DaisyUI message tag mapping
├── management/commands/  # Django management commands
│   ├── start_scheduler.py   # Start APScheduler
│   ├── detect_ngrok.py      # Auto-detect ngrok URL
│   ├── debug_transcripts.py # Debug call transcripts
│   ├── fetch_transcript.py  # Manually fetch transcript from API
│   ├── check_scheduler.py   # Diagnose scheduler issues
│   ├── debug_call.py        # Debug specific call attempt
│   └── clean_database.py    # Clear database for clean start
└── templates/voice/   # HTML templates
    ├── base.html      # Base template with Tailwind/DaisyUI
    ├── login.html     # Login page
    ├── manager/       # Superuser/Manager templates
    │   ├── dashboard.html
    │   ├── programmed_calls.html  # View/manage all calls
    │   ├── prompt_list.html
    │   ├── prompt_form.html
    │   ├── agent_list.html
    │   ├── logs.html
    │   └── ngrok_webhook_status.html
    └── agent/         # Sales agent templates
        ├── dashboard.html  # Timeline view with scheduled calls
        ├── meeting_detail.html
        └── profile.html
```

### Design Patterns

1. **DRY (Don't Repeat Yourself):**
   - Database queries centralized in `selectors.py`
   - Business logic organized in `services/` package (modular by domain)
   - Reusable utilities in `utils.py`

2. **Class-Based Views (Thing View Pattern):**
   - All views use Django's class-based views
   - Consistent structure and behavior
   - Mixin-based access control (SuperuserRequiredMixin, SalesAgentRequiredMixin)

3. **Separation of Concerns:**
   - Views handle HTTP requests/responses
   - Services contain business logic
   - Selectors handle database queries
   - Models define data structure
   - Tasks handle async/periodic operations

## Features

### Authentication System

- **Login:** Custom login page with username/password authentication
- **Logout:** Custom logout page with confirmation
- **Remember Me:** Optional session persistence (14 days when checked)
- **Session Management:** Configurable session expiry
- **Protected Views:** Login-required pages using mixins
- **Role-Based Access:** Superuser and Sales Agent dashboards

### User Interface

- **Responsive Design:** Mobile-friendly using Tailwind CSS
- **Modern UI:** DaisyUI components for consistent styling
- **Message System:** Toast notifications for user feedback
- **Form Validation:** Client and server-side validation with error display
- **Programmed Calls Dashboard:** View, filter, and manually trigger calls

### Core Functionality

#### 1. Google Calendar Integration
- OAuth 2.0 authentication flow with database token storage
- **Real-time Push Notifications:** Google Calendar watches for instant updates
- Automatic calendar sync (background task syncs today's meetings)
- Manual sync trigger
- Sync status dashboard
- Meeting creation/updates from calendar events
- **Automatic call re-programming** when meeting times change
- **Call cancellation** when meetings are deleted

#### 2. Hybrid Call Scheduling System
The system uses a **hybrid approach** combining pre-programming with real-time checks:

**Pre-Programming (Primary):**
- When meetings are created/synced, `CallAttempt` records are pre-created with specific `scheduled_time`
- Provides visibility: see all upcoming calls before they happen
- Resilient: calls are queued in database, survives restarts

**Time-Window Checks (Backup):**
- Scheduler runs every 5 minutes
- Catches any calls that weren't pre-programmed
- Handles edge cases (late meeting creation, etc.)

**Call Timing:**
- **Pre-Meeting Calls:**
  - Initial: 60 minutes before meeting
  - If failed/no answer: 30 minutes before meeting (auto-created on failure)
  - Retry: every 5 minutes until meeting starts
- **Post-Meeting Calls:**
  - Initial: 15 minutes after meeting ends
  - Retry: 30 minutes after meeting ends
  - Retry: every 5 minutes after meeting ends

**Rate Limiting:** Minimum 5 minutes between retry attempts

#### 3. Voice Call System (ElevenLabs Conversational AI)
- Dynamic AI prompts with meeting context injection
- **Prompt Overrides**: Custom prompts sent per call via ElevenLabs override API
  - Requires "Allow Overrides" enabled in agent Security settings
- Phone number validation (E.164 format)
- Call status tracking (Scheduled, Initiated, In Progress, Completed, No Answer, Failed)
- **Webhook Handling**: Real-time call status updates and transcript delivery
  - Webhook signature verification for security
  - Automatic transcript and summary extraction
  - Recording URL storage
- **API Polling Fallback**: Periodic sync for missed webhooks (runs every 15 minutes)
- **Conversation Summaries**: AI-generated summaries and titles from ElevenLabs
- Automatic retry logic for failed calls

#### 4. Pipedrive CRM Integration
- **Domain-Based Deal Search**: Extracts attendee emails from meetings, finds deals by company domain
- Deal search priority: External ID → Customer Name → Attendee Domain
- **Call Summary Syncing**: Posts AI-generated summaries (not full transcripts) to deals as notes
- Organization and deal lookup via Pipedrive API
- API token-based authentication

#### 5. Activity Logging
- Immutable audit trail for all system actions
- Log levels: DEBUG, INFO, WARNING, ERROR, CRITICAL
- Tracks: API calls, call attempts, sync operations, errors
- Filterable log explorer for superusers

### Security Features

- CSRF protection on all forms
- Password validation (Django validators)
- Secure session management
- Environment-based configuration (python-decouple)
- Production-ready secret key handling
- OAuth 2.0 for Google Calendar
- Database-stored OAuth credentials (encrypted in production)
- Production-oriented Django security settings for SSL, HSTS, secure cookies, and frame/content protections
- CI-enforced security checks: Ruff, djLint, Bandit, pip-audit, and Django deploy checks

### Webhook Security Notes

Current CSRF-exempt endpoints:
- `/webhooks/elevenlabs/`
- `/webhooks/twilio/`
- `/webhooks/google-calendar/`

Audit summary:
- `GoogleCalendarWebhookView` is intentionally CSRF-exempt and correlates requests using Google watch metadata (`X-Goog-Channel-ID` / channel token).
- `ElevenLabsWebhookView` is intentionally CSRF-exempt because it is machine-to-machine, but it does **not** currently verify a provider signature header in code.
- `TwilioWebhookView` is intentionally CSRF-exempt and does **not** currently verify `X-Twilio-Signature`.

Recommended next hardening steps:
- add explicit signature verification for ElevenLabs if the provider supports signed webhook delivery for this endpoint shape
- add Twilio signature validation or disable/remove the endpoint if it is not required
- optionally rate-limit webhook endpoints at the reverse proxy

## Data Models

### User (Custom Model)
- Extends Django's `AbstractUser`
- Fields: `pipedrive_user_id`, `phone_number`, `is_sales_agent`
- Used for sales agents who receive coaching calls

### VoicePrompt
- Editable system prompts for the AI agent
- Fields: `name`, `system_prompt`, `first_message`, `prompt_type` (PRE/POST), `is_active`
- Unique constraint: Only one active prompt per type
- Supports dynamic context injection (customer name, meeting title, etc.)

### Meeting
- Trigger events from Google Calendar
- Fields: `agent`, `external_id`, `title`, `customer_name`, `attendees` (JSONField), `start_time`, `end_time`
- State tracking: `is_pre_call_completed`, `is_post_call_completed`
- `attendees`: List of email addresses for domain-based Pipedrive matching

### CallAttempt
- Individual call records with pre-programming support
- Fields: `meeting`, `phase` (PRE/POST), `scheduled_offset_minutes`, `scheduled_time`, `external_call_id`, `status`, `recording_url`, `transcript`, `summary`, `summary_title`, `executed_at`
- `scheduled_time`: Pre-calculated execution time for hybrid scheduling
- `summary`: AI-generated conversation summary from ElevenLabs

### GoogleOauthCredential
- Stores Google OAuth tokens in database for background tasks
- Fields: `user`, `token`, `refresh_token`, `token_uri`, `client_id`, `client_secret`, `scopes`, `expires_at`
- Enables calendar sync without active user session

### GoogleCalendarWatch
- Tracks Google Calendar push notification channels
- Fields: `user`, `channel_id`, `resource_id`, `expiration`
- Enables real-time calendar updates

### ActivityLog
- Immutable audit log
- Fields: `meeting`, `user`, `action`, `details` (JSON), `level`, `timestamp`
- Records all system actions for debugging and compliance

## Core Logic & Workflow

### 1. Calendar Sync Flow

```
User authenticates with Google → OAuth callback → Store credentials in database
    ↓
Setup Google Calendar Watch (push notifications)
    ↓
Google Calendar changes → Push notification to /webhooks/google-calendar/
    ↓
Fetch today's events from Google Calendar API
    ↓
Create/Update Meeting records using update_or_create (atomic upsert)
    ↓
Pre-program CallAttempts for new/updated meetings
    ↓
Cancel calls for deleted meetings
    ↓
Log activity
```

### 2. Call Pre-Programming Flow

```
Meeting created/updated → pre_program_meeting_calls()
    ↓
Calculate scheduled_time for each offset:
    - PRE: meeting.start_time + offset (-60 min initially)
    - POST: meeting.end_time + offset (+15, +30 min)
    ↓
Create CallAttempt records with status=SCHEDULED
    ↓
If -60 call fails → auto-create -30 call
    ↓
Failed calls retry every 5 minutes (rate limited)
```

### 3. Call Execution Flow

```
APScheduler (every 5 mins) → check_and_trigger_calls()
    ↓
PRIMARY: Query CallAttempt where status=SCHEDULED AND scheduled_time <= now
    ↓
Validate timing (meeting hasn't started for PRE, meeting ended for POST)
    ↓
Execute call via execute_scheduled_call()
    ↓
RETRY: Query failed calls, retry if 5+ minutes since last attempt
    ↓
BACKUP: Window-based check for missed pre-programming
    ↓
trigger_agent_call() → ElevenLabs API
    ↓
Update CallAttempt status
```

### 4. Webhook Flow (Call Completion)

```
ElevenLabs → POST /webhooks/elevenlabs/
    ↓
Parse webhook payload:
    - Extract call_id, status, transcript, summary, summary_title, recording_url
    ↓
Find CallAttempt by external_call_id
    ↓
Update CallAttempt with transcript, summary, recording_url, status
    ↓
If -60 pre-call failed → auto-create -30 call
    ↓
Update Meeting: is_pre_call_completed or is_post_call_completed
    ↓
If POST call completed → sync_note_to_pipedrive() (uses summary, finds deal by domain)
    ↓
Log activity
```

### 5. Pipedrive Sync Flow

```
Post-meeting call completed → sync_note_to_pipedrive()
    ↓
Get meeting attendees → extract domains from emails
    ↓
For each domain:
    - Search Pipedrive organization by domain
    - Get deals for organization (prefer open deals)
    ↓
Post call summary as note to deal
    ↓
Log activity
```

## Configuration

### Environment Variables

Create a `.env` file in the project root:

```env
# Django Settings
SECRET_KEY=your-secret-key-here
DEBUG=True
ALLOWED_HOSTS=localhost,127.0.0.1

# Google Calendar Integration
GOOGLE_CLIENT_ID=your-google-client-id.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=your-google-client-secret
GOOGLE_REDIRECT_URI=http://localhost:8000/calendar/callback/
# For push notifications (optional, uses ngrok URL if available)
GOOGLE_CALENDAR_WEBHOOK_URL=https://your-domain.com/webhooks/google-calendar/

# ElevenLabs Integration
ELEVENLABS_API_KEY=your-elevenlabs-api-key
ELEVENLABS_WEBHOOK_URL=http://localhost:8000/webhooks/elevenlabs/
ELEVENLABS_AGENT_ID=your-agent-id
ELEVENLABS_PHONE_NUMBER_ID=your-phone-number-id
ELEVENLABS_WEBHOOK_SECRET=your-secret-key-from-elevenlabs-dashboard

# Twilio Integration (credentials used when importing number to ElevenLabs)
TWILIO_ACCOUNT_SID=your-twilio-account-sid
TWILIO_AUTH_TOKEN=your-twilio-auth-token
TWILIO_PHONE_NUMBER=+1234567890

# Base URL (for webhook URLs)
BASE_URL=http://localhost:8000

# Pipedrive Integration
PIPEDRIVE_API_TOKEN=your-pipedrive-api-token
PIPEDRIVE_DOMAIN=your-pipedrive-domain

# Ngrok API (for auto-detection)
NGROK_API_URL=http://localhost:4040/api/tunnels
```

### Key Settings

- **LOGIN_URL:** `/login/` - Where unauthenticated users are redirected
- **LOGIN_REDIRECT_URL:** `/` - Where users go after successful login
- **AUTH_USER_MODEL:** `voice.User` - Custom user model
- **SECURE_PROXY_SSL_HEADER:** Configured for ngrok HTTPS detection

### APScheduler Configuration

- **Job Storage:** Database (uses Django's database - no Redis needed!)
- **Periodic Tasks:**
  - `check_and_trigger_calls`: Every 5 minutes (executes pre-programmed calls, retries failed calls)
  - `sync_all_user_calendars`: Every hour (syncs today's meetings for all agents)
  - `sync_pending_calls`: Every 15 minutes (syncs call status from API for missed webhooks)

## Setup Instructions

### 1. Prerequisites

- `uv` installed: https://docs.astral.sh/uv/
- Python 3.12 (uv will install/manage it for you)
- Google Cloud Console project (for Calendar API)
- ElevenLabs account and API key
- Twilio account and credentials
- Pipedrive account and API token

### 2. Install Python and Dependencies with uv

```bash
uv python install 3.12
uv sync --locked
```

This project now uses:
- `pyproject.toml` for dependency definitions
- `uv.lock` for reproducible installs
- `.python-version` to pin local development to Python 3.12

### 3. Environment Variables

Copy `env.example` to `.env` and update with your values:

```bash
# Windows
copy env.example .env

# Linux/Mac
cp env.example .env
```

### 4. Run Migrations

```bash
uv run python manage.py migrate
```

### 5. Create Superuser

```bash
uv run python manage.py createsuperuser
```

### 6. Set Up Google Calendar OAuth

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select existing
3. Enable Google Calendar API
4. Create OAuth 2.0 credentials (Web application)
5. Add authorized redirect URIs:
   - `http://localhost:8000/calendar/callback/` (development)
   - `https://your-ngrok-url.ngrok-free.dev/calendar/callback/` (ngrok testing)
6. Copy Client ID and Client Secret to `.env`

### 7. Set Up ElevenLabs

1. Go to [ElevenLabs](https://elevenlabs.io/)
2. Create an account and get API key
3. Create an agent in the Conversational AI section
4. **Enable Prompt Overrides:**
   - Go to agent's Security tab
   - Enable "Allow Overrides" for System prompt
5. Import your Twilio phone number
6. **Configure Webhook:**
   - Create a "Post Call" webhook
   - Use ngrok URL for local development
   - Copy webhook secret to `.env`

### 8. Set Up Pipedrive

1. Go to your Pipedrive account
2. Navigate to Settings → API
3. Generate API token
4. Note your domain (subdomain part of URL)
5. Add to `.env`

## Running the System

### Development Setup

You need to run **3 processes** for full functionality:

#### 1. Start ngrok (for webhooks)

```bash
ngrok http 8000
```

#### 2. Start Django Development Server

```bash
uv run python manage.py runserver
```

#### 3. Start APScheduler (Task Scheduler)

In a separate terminal:

```bash
uv run python manage.py start_scheduler
```

### Access Points

- **Main app:** `http://127.0.0.1:8000/`
- **Login:** `http://127.0.0.1:8000/login/`
- **Admin panel:** `http://127.0.0.1:8000/admin/`
- **Superuser Dashboard:** `http://127.0.0.1:8000/dashboard/admin/`
- **Programmed Calls:** `http://127.0.0.1:8000/manager/calls/`
- **Sales Agent Dashboard:** `http://127.0.0.1:8000/dashboard/agent/`
- **Calendar Sync Status:** `http://127.0.0.1:8000/calendar/status/`
- **Ngrok Webhook Status:** `http://127.0.0.1:8000/webhooks/ngrok-status/`

## URL Routing

```
/                           → HomeView (redirects based on role)
/login/                     → CustomLoginView
/logout/                    → CustomLogoutView
/admin/                     → Django admin panel

# Google Calendar
/calendar/oauth/             → GoogleCalendarOAuthView (initiate OAuth)
/calendar/callback/          → GoogleCalendarCallbackView (OAuth callback + setup watch)
/calendar/sync/              → CalendarSyncTriggerView (manual sync trigger)
/calendar/status/            → CalendarSyncStatusView (sync dashboard)

# Webhooks
/webhooks/elevenlabs/        → ElevenLabsWebhookView (call completion, transcripts, summaries)
/webhooks/twilio/            → TwilioWebhookView (optional, for additional tracking)
/webhooks/google-calendar/   → GoogleCalendarWebhookView (push notifications)
/webhooks/ngrok-status/      → NgrokWebhookStatusView (webhook URL management)

# Manager/Superuser
/dashboard/admin/            → SuperuserDashboardView
/dashboard/admin/test-call/  → TestCallView (trigger test call)
/manager/prompts/            → PromptListView
/manager/prompts/<id>/edit/  → PromptEditView
/manager/agents/             → AgentManagementView
/manager/logs/               → AuditLogExplorerView
/manager/calls/              → ProgrammedCallsView (view all scheduled/executed calls)
/manager/calls/trigger/      → ManualCallTriggerView (manually trigger a call)

# Sales Agent
/dashboard/agent/            → SalesAgentDashboardView (timeline view)
/meeting/<id>/               → MeetingDetailView
/profile/                    → SalesAgentProfileView
```

## Management Commands

### `start_scheduler`
Starts the APScheduler for periodic tasks.

```bash
uv run python manage.py start_scheduler
```

**Important:** Must be running for automatic call scheduling.

### `detect_ngrok`
Auto-detects ngrok URL and shows webhook configuration instructions.

```bash
uv run python manage.py detect_ngrok
```

### `clean_database`
Clears database for a clean start (preserves users and prompts).

```bash
uv run python manage.py clean_database --force
```

Deletes: ActivityLog, CallAttempt, Meeting, GoogleCalendarWatch, GoogleOauthCredential

### `check_scheduler`
Diagnoses scheduler's meeting detection.

```bash
uv run python manage.py check_scheduler
```

Shows: meetings in time windows, existing call attempts, scheduler function results.

### `debug_call`
Debug a specific call attempt.

```bash
uv run python manage.py debug_call <call_attempt_id>
```

### `debug_transcripts`
Inspect recent calls and transcripts.

```bash
uv run python manage.py debug_transcripts --limit 10
```

### `fetch_transcript`
Manually retrieve transcript from ElevenLabs API.

```bash
uv run python manage.py fetch_transcript <external_call_id>
```

## Constants

Defined in `voice/constants.py`:

- `CallStatus`: SCHEDULED, INITIATED, IN_PROGRESS, COMPLETED, NO_ANSWER, FAILED
- `CallPhase`: PRE (Pre-Meeting Training), POST (Post-Meeting Debrief)
- `LogLevel`: DEBUG, INFO, WARNING, ERROR, CRITICAL
- `PRE_MEETING_OFFSETS`: `[-60, -30]` (minutes before meeting)
- `POST_MEETING_OFFSETS`: `[15, 30]` (minutes after meeting)
- `SCHEDULER_WINDOW`: `10` (minutes tolerance for time-based checks)
- `MAX_RETRY_ATTEMPTS`: `3`
- `RETRY_DELAY_SECONDS`: `60`

## Current State

### ✅ Implemented Features

**Core System**
- ✅ Custom User model with sales agent fields
- ✅ VoicePrompt model for AI agent prompts with first_message support
- ✅ Meeting model with attendees JSONField for Pipedrive integration
- ✅ CallAttempt model with scheduled_time and summary fields
- ✅ ActivityLog model for audit trail
- ✅ GoogleOauthCredential model for database token storage
- ✅ GoogleCalendarWatch model for push notifications
- ✅ Constants and enums defined
- ✅ Models registered in admin with custom displays

**Google Calendar Integration**
- ✅ OAuth 2.0 authentication flow with ngrok HTTPS support
- ✅ Database-stored credentials for background sync
- ✅ Real-time push notifications via Google Calendar Watch API
- ✅ Automatic meeting deletion detection and call cancellation
- ✅ Atomic upserts using update_or_create
- ✅ Explicit UTC timezone handling
- ✅ Today-only sync (start of day to end of day)

**Call Scheduling (Hybrid Approach)**
- ✅ Pre-programming of CallAttempts when meetings are created
- ✅ Scheduler executes pre-programmed calls
- ✅ Backup window-based check for missed calls
- ✅ Auto-retry failed calls every 5 minutes
- ✅ Auto-create -30 call when -60 call fails
- ✅ Rate limiting (minimum 5 minutes between retries)
- ✅ 5-minute grace period for late meeting creation

**ElevenLabs Integration**
- ✅ Dynamic prompt formatting with context
- ✅ Call initiation via ElevenLabs API
- ✅ Webhook handling for transcripts and summaries
- ✅ API polling fallback for missed webhooks
- ✅ Conversation summary extraction and storage
- ✅ Ngrok URL auto-detection

**Pipedrive Integration**
- ✅ Domain-based deal search from attendee emails
- ✅ Organization lookup by domain
- ✅ Call summary syncing (not full transcript)
- ✅ Deal creation/update support

**User Interface**
- ✅ Superuser dashboard with statistics
- ✅ Programmed Calls view with filtering
- ✅ Manual call trigger functionality
- ✅ Sales agent timeline view showing scheduled call times
- ✅ Meeting detail view with pre/post call tabs
- ✅ Responsive design with Tailwind/DaisyUI

**Task Scheduling (APScheduler)**
- ✅ No Redis required - uses database
- ✅ check_and_trigger_calls (every 5 minutes)
- ✅ sync_all_user_calendars (every hour, today only)
- ✅ sync_pending_calls (every 15 minutes)

## Troubleshooting

### Common Issues

1. **Scheduler not finding meetings:**
   - Run `uv run python manage.py check_scheduler` to diagnose
   - Ensure meetings are for today (sync only fetches today's meetings)
   - Check that agent has `is_sales_agent=True` and `phone_number` set

2. **Google Calendar OAuth errors:**
   - Ensure ngrok is running for HTTPS
   - Check `SECURE_PROXY_SSL_HEADER` is configured in settings
   - Verify redirect URI matches in Google Cloud Console

3. **Calls not triggering:**
   - Ensure scheduler is running: `uv run python manage.py start_scheduler`
   - Check for active VoicePrompt for the phase
   - Verify CallAttempt.scheduled_time is correct

4. **Webhook not receiving data:**
   - Ensure ngrok is running: `ngrok http 8000`
   - Run `uv run python manage.py detect_ngrok` for configuration
   - Check webhook URL in ElevenLabs dashboard
   - Verify webhook secret matches `.env`

5. **Calendar sync fetching wrong dates:**
   - Manual sync and background sync both use today-only range
   - Delete old meetings with `uv run python manage.py clean_database --force`

## Production Deployment

### Checklist

- [ ] Set `DEBUG=False`
- [ ] Set strong `SECRET_KEY`
- [ ] Configure `ALLOWED_HOSTS`
- [ ] Use PostgreSQL instead of SQLite
- [ ] Encrypt OAuth credentials in database
- [ ] Configure SSL/HTTPS
- [ ] Update webhook URLs to production domain
- [ ] Set up monitoring for scheduler process
- [ ] Configure logging to external service
- [ ] Set up database backups

### Recommended Production Stack

- **Process/runtime:** `uv` + `uv.lock`
- **Web Server:** Gunicorn + Nginx
- **Database:** PostgreSQL
- **Task Scheduler:** django-apscheduler (runs as separate process)
- **Static Files:** CDN or S3
- **Monitoring:** Sentry for error tracking

### Production Commands

Install exactly what is locked:

```bash
uv sync --locked --no-dev
```

Run the web app:

```bash
uv run gunicorn proj_mes_voice.wsgi:application --bind 0.0.0.0:8000
```

Run the scheduler in a separate process:

```bash
uv run python manage.py start_scheduler
```

## Development Guidelines

### Adding New Features

1. **Models:** Define in `voice/models.py`, run `makemigrations`
2. **Database Queries:** Add to `voice/selectors.py`
3. **Business Logic:** Add to appropriate module in `voice/services/`:
   - `logging.py`: Activity logging
   - `pipedrive.py`: Pipedrive CRM operations
   - `elevenlabs.py`: ElevenLabs voice operations
   - `google_calendar.py`: Calendar sync operations
   - `scheduler.py`: Call scheduling logic
   - Don't forget to export new functions in `__init__.py`
4. **Views:** Create CBVs in `voice/views.py`
5. **URLs:** Add patterns to `voice/urls.py`
6. **Templates:** Create in `voice/templates/voice/`
7. **Tasks:** Add to `voice/tasks.py` for scheduled operations

### Code Organization

- `services/`: Modular package containing all business logic, split by domain:
  - `logging.py` (~55 lines): Activity logging
  - `pipedrive.py` (~330 lines): Pipedrive CRM integration
  - `elevenlabs.py` (~550 lines): ElevenLabs voice AI
  - `google_calendar.py` (~550 lines): Google Calendar sync
  - `scheduler.py` (~230 lines): Call scheduling logic
  - All functions re-exported from `__init__.py` for backward compatibility

## License

[Add your license here]

## Contact

[Add contact information here]
