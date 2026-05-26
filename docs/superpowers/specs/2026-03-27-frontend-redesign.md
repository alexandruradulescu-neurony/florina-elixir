# Frontend Redesign — Design Spec

## Summary

Transform the current top-navbar layout into a modern dashboard application with a persistent dark sidebar, teal/emerald accent color, and clean content area. All 22 templates will be updated. No new dependencies — continues using Tailwind CSS + DaisyUI via CDN.

## Design Decisions

- **Layout**: Dark sidebar (slate/charcoal `#0f172a`) + light content area (`#f1f5f9`)
- **Accent color**: Teal/emerald (`#14b8a6` primary, `#0d9488` hover)
- **Sidebar**: Persistent on desktop (220px), hidden on mobile with hamburger toggle
- **Mobile**: Sidebar slides in as a drawer overlay from the left. Tap outside (on overlay backdrop) to close.
- **Both roles use sidebar**: Managers see full nav, agents see their subset
- **DaisyUI theme**: Keep `light` theme, override accent colors via Tailwind config
- **No JS libraries**: Sidebar toggle is vanilla JS (one click handler)

## Sidebar Structure

### Manager Nav
```
[Logo] Sales Assistant
       Manager

--- Overview ---
  Dashboard        → /dashboard/admin/
  Visits           → /manager/visits/
  Calendar         → /manager/calendar/

--- Manage ---
  Agents           → /manager/agents/
  Methodologies    → /manager/methodologies/
  Calls            → /manager/calls/
  Prompts          → /manager/prompts/
  Logs             → /manager/logs/

--- bottom ---
  Settings         → /manager/settings/
  [Avatar] Admin   → Logout
```

### Agent Nav
```
[Logo] Sales Assistant
       Sales Agent

--- Overview ---
  My Schedule      → /dashboard/agent/
  Calendar Sync    → /calendar/status/

--- Account ---
  Profile          → /profile/

--- bottom ---
  [Avatar] Username → Logout
```

## Template Changes

### base.html — Complete Rewrite

Replace the navbar layout with a sidebar layout:

```
<body>
  <!-- Sidebar (hidden on mobile by default) -->
  <aside id="sidebar" class="fixed inset-y-0 left-0 w-56 bg-[#0f172a] transform -translate-x-full md:translate-x-0 transition-transform z-40">
    ... nav content ...
  </aside>

  <!-- Mobile overlay -->
  <div id="sidebar-overlay" class="fixed inset-0 bg-black/50 z-30 hidden md:hidden"></div>

  <!-- Main wrapper (offset by sidebar width on desktop) -->
  <div class="md:ml-56 min-h-screen bg-[#f1f5f9]">
    <!-- Mobile menu button (fixed, hidden on desktop) -->
    <button onclick="toggleSidebar()" class="md:hidden fixed top-4 left-4 z-20 ...">
      open drawer icon
    </button>

    <!-- Page top bar (always visible) -->
    <header class="bg-white border-b border-gray-200 px-6 py-4">
      {% block page_header %}{% endblock %}
    </header>

    <!-- Toast messages -->
    {% if messages %}...{% endif %}

    <!-- Page content -->
    <main class="p-6">
      {% block content %}{% endblock %}
    </main>
  </div>

  <script>sidebar toggle logic</script>
</body>
```

### New blocks available to child templates

- `{% block page_header %}` — page title bar (title + subtitle + action buttons)
- `{% block content %}` — main content area (unchanged)

### All 22 child templates

Each child template needs:
1. Remove `<div class="container mx-auto px-4 py-8">` wrapper (base provides padding)
2. Move the `<h1>` and subtitle into `{% block page_header %}`
3. Content stays in `{% block content %}`

No functional changes to any template — just structural wrapping.

## Color Palette

| Usage | Color | Hex |
|-------|-------|-----|
| Sidebar bg | Slate 950 | `#0f172a` |
| Sidebar hover | Slate 800 | `#1e293b` |
| Sidebar text | Slate 400 | `#94a3b8` |
| Sidebar active bg | Teal/10% | `#14b8a620` |
| Sidebar active text | Teal 400 | `#14b8a6` |
| Content bg | Slate 100 | `#f1f5f9` |
| Card bg | White | `#ffffff` |
| Card border | Slate 200 | `#e2e8f0` |
| Primary action | Teal 500 | `#14b8a6` |
| Primary hover | Teal 600 | `#0d9488` |
| Text primary | Slate 900 | `#0f172a` |
| Text secondary | Slate 500 | `#64748b` |

## DaisyUI Theme Override

In the Tailwind config block in base.html:
```js
tailwind.config = {
  theme: {
    extend: {
      colors: {
        primary: '#14b8a6',
        'primary-focus': '#0d9488',
      }
    }
  },
  daisyui: {
    themes: [{
      light: {
        ...require("daisyui/src/theming/themes")["light"],
        primary: '#14b8a6',
        'primary-focus': '#0d9488',
        'primary-content': '#ffffff',
      }
    }],
  },
}
```

Since we use CDN, we'll set the DaisyUI primary via CSS custom properties instead:
```css
[data-theme="light"] {
  --p: 168 64% 40%;  /* teal-500 in HSL */
  --pf: 168 64% 32%; /* teal-600 */
  --pc: 0 0% 100%;   /* white */
}
```

## Scope

- **In scope**: base.html rewrite, all 22 child template adaptations, sidebar JS, color scheme
- **Out of scope**: New pages, new features, backend changes, login page (keeps centered card layout, no sidebar)
- **Login/Logout pages**: These are public pages — no sidebar, keep simple centered layout with the new color scheme applied

## Files Modified

- `voice/templates/voice/base.html` — full rewrite
- `voice/templates/voice/login.html` — standalone layout (no sidebar), updated colors
- `voice/templates/voice/logged_out.html` — same as login
- `voice/templates/voice/home.html` — adapt to new block structure
- `voice/templates/voice/calendar_sync_status.html` — adapt
- `voice/templates/voice/agent/dashboard.html` — adapt
- `voice/templates/voice/agent/meeting_detail.html` — adapt
- `voice/templates/voice/agent/profile.html` — adapt
- `voice/templates/voice/manager/dashboard.html` — adapt
- `voice/templates/voice/manager/visit_list.html` — adapt
- `voice/templates/voice/manager/visit_calendar.html` — adapt
- `voice/templates/voice/manager/visit_detail.html` — adapt
- `voice/templates/voice/manager/agent_list.html` — adapt
- `voice/templates/voice/manager/agent_form.html` — adapt
- `voice/templates/voice/manager/programmed_calls.html` — adapt
- `voice/templates/voice/manager/prompt_list.html` — adapt
- `voice/templates/voice/manager/prompt_form.html` — adapt
- `voice/templates/voice/manager/methodology_list.html` — adapt
- `voice/templates/voice/manager/methodology_form.html` — adapt
- `voice/templates/voice/manager/settings.html` — adapt
- `voice/templates/voice/manager/logs.html` — adapt
- `voice/templates/voice/manager/ngrok_webhook_status.html` — adapt
