# Claude Design Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current Tailwind/DaisyUI shell with the new Editorial-Minimalism-×-Warm-Scheduling design system foundation — tokens, fonts, icons, a new `base.html` shell (264 px white sidebar + two-row header), and 3 reusable component partials. No screen-level redesigns in this pass.

**Architecture:** Drop Tailwind CDN + DaisyUI entirely. Ship the design package's tokens and icon CSS sprite as Django static files. Hand-roll a `shell.css` containing the sidebar, header, canvas, and reusable component classes (extracted from the design's `dashboard.css` chrome region). Rewrite `base.html` to consume them with role-aware nav. Patch the three small auth-adjacent screens (`login`, `logged_out`, `home`) so they don't render bare. Every other template breaks visually — accepted transition cost.

**Tech Stack:** Django 4.2 templates, hand-rolled CSS (no preprocessor), Google Fonts (Nunito + Nunito Sans, loaded via `<link>` tag), Flaticon UIcons filled-rounded family (shipped as a CSS sprite with inline data-URL `mask-image`).

**Source spec:** [docs/superpowers/specs/2026-05-26-claude-design-foundation-design.md](../specs/2026-05-26-claude-design-foundation-design.md)

**Source design package (local working copy):** `/tmp/claude-design/sales-assistant-calendar-design-system/`

---

## Conventions for this plan

- Dev server port: `8003` (per user memory).
- The Python command is `python manage.py …` — run from the repo root.
- All file paths in this plan are relative to the repo root (`/Users/alex/Code/proj-salesassistant`).
- "Manager" in the UI = `user.is_superuser` in the model. "Sales Agent" = `user.is_sales_agent`.
- Each task ends with a commit. Don't batch commits across tasks.

---

### Task 1: Ship design tokens, icons, and the static directory

**Why:** Nothing else in this plan can render without these assets.

**Files:**
- Create: `static/css/tokens.css`
- Create: `static/css/icons.css`
- Create: `static/icons/` (directory with 24 SVG files)

**Source files in the design package:**
- `/tmp/claude-design/sales-assistant-calendar-design-system/project/assets/colors_and_type.css`
- `/tmp/claude-design/sales-assistant-calendar-design-system/project/assets/icons.css`
- `/tmp/claude-design/sales-assistant-calendar-design-system/project/assets/icons/` (24 SVGs)

- [ ] **Step 1: Create the static directories**

```bash
mkdir -p static/css static/icons
```

- [ ] **Step 2: Write `static/css/tokens.css`**

This is the design package's `colors_and_type.css` adapted: the `@import url(...)` line is dropped (Google Fonts loads from `base.html` via `<link>` instead), the `@font-face` block is dropped (italic Nunito not used in the product), and the missing tokens called out in the spec (§4) are added (`--border-default`, the cyan/orange/green/rose/amber chip palette).

Write the entire contents:

```css
/* ============================================================================
   Sales Assistant — Design Tokens
   Adapted from claude-design export 2026-05-26.
   Single source of truth for color, type, spacing, radii, shadows.
   ============================================================================ */

:root {
  /* ─────────── Neutrals (Zinc scale) ─────────── */
  --zinc-950: rgb(24, 24, 27);     /* fg-strong, active pill fill */
  --zinc-900: rgb(38, 38, 42);
  --zinc-700: rgb(63, 63, 70);     /* fg */
  --zinc-500: rgb(113, 113, 123);  /* fg-muted */
  --zinc-400: rgb(159, 159, 169);  /* fg-faint */
  --zinc-300: rgb(212, 212, 216);  /* default hairline */
  --zinc-200: rgb(228, 228, 231);  /* light hairline */
  --zinc-100: rgb(244, 244, 245);  /* canvas */
  --zinc-50:  rgb(250, 250, 250);  /* offwhite */
  --zinc-25:  rgb(252, 252, 252);
  --white:    rgb(255, 255, 255);
  --black:    rgb(0, 0, 0);

  /* ─────────── Cyan — primary ─────────── */
  --cyan-50:  rgb(236, 254, 255);   /* "this week" tint */
  --cyan-100: rgb(207, 250, 254);   /* event chip fill */
  --cyan-200: rgb(162, 244, 253);
  --cyan-500: rgb(0, 184, 219);     /* primary CTA */
  --cyan-600: rgb(8, 145, 178);     /* primary CTA hover */

  /* ─────────── Orange — secondary accent ─────────── */
  --orange-100: rgb(255, 237, 213);
  --orange-500: rgb(255, 105, 0);
  --orange-700: rgb(159, 45, 0);

  /* ─────────── Pastel state chips ─────────── */
  --green-100: rgb(220, 252, 231);
  --green-700: rgb(21, 128, 61);
  --rose-100:  rgb(255, 228, 230);
  --rose-700:  rgb(190, 18, 60);
  --amber-100: rgb(254, 243, 199);  /* cream */
  --amber-800: rgb(146, 64, 14);

  /* ─────────── Semantic foreground ─────────── */
  --fg-strong: var(--zinc-950);
  --fg:        var(--zinc-700);
  --fg-muted:  var(--zinc-500);
  --fg-faint:  var(--zinc-400);
  --fg-dim:    var(--zinc-400);
  --fg-on-accent: var(--white);

  /* ─────────── Semantic surfaces ─────────── */
  --bg-canvas:  var(--zinc-100);
  --bg-surface: var(--white);
  --bg-card:    var(--white);
  --bg-tint:    var(--cyan-50);

  /* ─────────── Borders ─────────── */
  --border:         var(--zinc-300);
  --border-default: var(--zinc-300);
  --border-hairline:var(--zinc-200);
  --border-strong:  var(--zinc-950);

  /* ─────────── Shadows ─────────── */
  --shadow-tile:  0.5px 1px 1.5px rgba(0,0,0,0.20);
  --shadow-card:  0 1px 4px rgba(0,0,0,0.10);
  --shadow-popup: 0 12px 24px rgba(0,0,0,0.10);

  /* ─────────── Radii ─────────── */
  --radius-sm:   4px;
  --radius-md:   8px;
  --radius-lg:   16px;
  --radius-pill: 9999px;

  /* ─────────── Spacing scale ─────────── */
  --space-1: 4px;
  --space-2: 8px;
  --space-3: 12px;
  --space-4: 16px;
  --space-5: 24px;
  --space-6: 32px;
  --space-7: 48px;
  --space-8: 64px;

  /* ─────────── Type ─────────── */
  --font-ui:   'Nunito', system-ui, -apple-system, 'Segoe UI', sans-serif;
  --font-tile: 'Nunito Sans', 'Nunito', system-ui, sans-serif;

  --t-display: 32px;
  --t-h1:      24px;
  --t-h2:      20px;
  --t-body:    16px;
  --t-meta:    14px;
  --t-caption: 12px;
  --t-micro:   10px;

  --lh-tight: 1;
  --lh-snug:  1.2;
  --lh-body:  1.4;

  /* ─────────── Focus ─────────── */
  --focus-ring: var(--cyan-500);
}

/* ─────────── Typography helpers (optional, screens can use them) ─────────── */
.t-display { font-family: var(--font-ui); font-weight: 800; font-size: var(--t-display); line-height: var(--lh-tight); color: var(--fg-strong); letter-spacing: -0.01em; }
.t-h1      { font-family: var(--font-ui); font-weight: 700; font-size: var(--t-h1);      line-height: var(--lh-tight); color: var(--fg-strong); }
.t-h2      { font-family: var(--font-ui); font-weight: 800; font-size: var(--t-h2);      line-height: var(--lh-snug);  color: var(--fg-strong); }
.t-body    { font-family: var(--font-ui); font-weight: 500; font-size: var(--t-body);    line-height: var(--lh-snug);  color: var(--fg-strong); }
.t-meta    { font-family: var(--font-ui); font-weight: 700; font-size: var(--t-meta);    line-height: var(--lh-tight); color: var(--fg-strong); }
.t-caption { font-family: var(--font-tile); font-weight: 700; font-size: var(--t-caption); line-height: var(--lh-tight); color: var(--fg-muted); }
.t-micro   { font-family: var(--font-ui); font-weight: 800; font-size: var(--t-micro);   line-height: var(--lh-tight); color: var(--fg-muted); letter-spacing: 0.1em; text-transform: uppercase; }
```

- [ ] **Step 3: Copy `icons.css` verbatim**

The design's `icons.css` is self-contained (each icon is an inline data URL inside `mask-image`). Copy it byte-for-byte:

```bash
cp /tmp/claude-design/sales-assistant-calendar-design-system/project/assets/icons.css static/css/icons.css
```

- [ ] **Step 4: Copy the icon SVG files**

The CSS sprite is self-contained, but we ship the raw SVGs too for places where data URLs are awkward (favicons, email, manual `<img>` tags later).

```bash
cp /tmp/claude-design/sales-assistant-calendar-design-system/project/assets/icons/*.svg static/icons/
```

- [ ] **Step 5: Verify the assets are present**

```bash
ls -la static/css/ static/icons/ | head -40
```

Expected: `tokens.css`, `icons.css` in `static/css/`; 24 SVG files in `static/icons/`.

- [ ] **Step 6: Verify Django can find them**

```bash
python manage.py collectstatic --dry-run --noinput 2>&1 | grep -E "tokens|icons" | head -10
```

Expected: lines mentioning `css/tokens.css`, `css/icons.css`, and several `.svg` paths.

- [ ] **Step 7: Commit**

```bash
git add static/
git commit -m "Foundation: ship design tokens, icons, fonts as static assets"
```

---

### Task 2: Write `shell.css` with sidebar, header, canvas, and component classes

**Why:** This is the visual rule set the new `base.html` consumes. It must exist before the shell rewrite.

**Files:**
- Create: `static/css/shell.css`

This file contains four logical regions, written as one file in one step. Reference: the design's `dashboard.css` lines 1–225 contain the canonical chrome and were the basis for these rules; component classes (`.pill`, `.count-badge`, `.stat`, `.tbl`) are extended to match §7 of the design spec.

- [ ] **Step 1: Write the complete `static/css/shell.css`**

```css
/* ============================================================================
   Sales Assistant — Shell + Components
   Sidebar, header, canvas layout, and reusable component class rules.
   Per the §14 theme-lock: Editorial Minimalism × Warm Scheduling,
   Nunito + Nunito Sans, cyan primary, black-pill chrome-selection,
   pastel-chip state, compact density.
   ============================================================================ */

*, *::before, *::after { box-sizing: border-box; }
html, body {
  margin: 0;
  background: var(--bg-canvas);
  color: var(--fg-strong);
  font-family: var(--font-ui);
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}
a { color: inherit; text-decoration: none; }
button {
  font-family: inherit;
  border: none;
  background: none;
  cursor: pointer;
  color: inherit;
  padding: 0;
}

/* ─────────── Icon sprite mixin (used by .ic-* from icons.css) ─────────── */
.ic {
  display: inline-block;
  background-color: currentColor;
  -webkit-mask-position: center;
  -webkit-mask-repeat: no-repeat;
  -webkit-mask-size: contain;
  mask-position: center;
  mask-repeat: no-repeat;
  mask-size: contain;
  flex: none;
  color: currentColor;
  width: 16px;
  height: 16px;
}
.ic-12 { width: 12px; height: 12px; }
.ic-14 { width: 14px; height: 14px; }
.ic-16 { width: 16px; height: 16px; }
.ic-18 { width: 18px; height: 18px; }
.ic-20 { width: 20px; height: 20px; }

/* ─────────── App shell layout ─────────── */
.app-shell {
  display: grid;
  grid-template-columns: 264px 1fr;
  min-height: 100vh;
}
.app-main {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

/* ─────────── Sidebar ─────────── */
.sb {
  background: var(--bg-surface);
  border-right: 1px solid var(--border-hairline);
  display: flex;
  flex-direction: column;
  padding: 18px 14px 16px;
  gap: 4px;
  min-height: 100vh;
  position: sticky;
  top: 0;
}
.sb .brand {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 6px 8px 14px;
}
.sb .brand .mark {
  width: 36px; height: 36px;
  border-radius: 10px;
  background: var(--cyan-500);
  color: #fff;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 18px;
  line-height: 1;
}
.sb .brand .nm {
  font-weight: 700;
  font-size: 14px;
  line-height: 1.1;
  color: var(--fg-strong);
  white-space: nowrap;
}
.sb .brand .role {
  font-weight: 500;
  font-size: 12px;
  color: var(--fg-muted);
  line-height: 1;
  margin-top: 4px;
  white-space: nowrap;
}

.sb .group { display: flex; flex-direction: column; gap: 2px; }
.sb .group h4 {
  margin: 18px 12px 6px;
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--fg-muted);
}

.sb .row {
  display: flex;
  align-items: center;
  gap: 12px;
  height: 40px;
  padding: 0 8px;
  border-radius: var(--radius-pill);
  text-decoration: none;
  color: var(--fg-strong);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 14px;
  line-height: 1;
  cursor: pointer;
  transition: background-color 120ms ease-out, color 120ms ease-out;
  user-select: none;
}
.sb .row:hover { background: var(--zinc-100); }
.sb .row .iconslot {
  width: 32px; height: 32px;
  border-radius: 8px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: none;
}
.sb .row .iconslot .ic { width: 18px; height: 18px; color: var(--fg-strong); }
.sb .row .label { flex: 1; }
.sb .row .count {
  margin-left: auto;
  background: var(--zinc-950);
  color: #fff;
  font-size: 11px;
  font-weight: 800;
  height: 18px;
  min-width: 22px;
  padding: 0 7px;
  border-radius: var(--radius-pill);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  letter-spacing: 0.01em;
}
.sb .row.active { background: var(--zinc-950); color: #fff; }
.sb .row.active .iconslot .ic { color: #fff; }
.sb .row.active .count { background: #fff; color: var(--zinc-950); }

.sb .spacer { flex: 1; }

.sb .settings-row {
  /* same as .row but always sits above the admin block; no special variant */
}

.sb .me {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 14px 8px 8px;
  margin-top: 6px;
  border-top: 1px solid var(--border-hairline);
}
.sb .me .av {
  width: 32px; height: 32px;
  border-radius: 50%;
  background: var(--cyan-500);
  color: #fff;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-weight: 800;
  font-size: 13px;
  flex: none;
}
.sb .me .nm {
  font-weight: 700;
  font-size: 13px;
  line-height: 1.1;
  color: var(--fg-strong);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.sb .me .role {
  font-weight: 500;
  font-size: 12px;
  color: var(--fg-muted);
  line-height: 1;
  margin-top: 3px;
}
.sb .me .role a { color: var(--fg-muted); }
.sb .me .role a:hover { color: var(--fg-strong); }

/* ─────────── Header — Row 1 (utility) ─────────── */
.hdr-utility {
  height: 64px;
  padding: 0 32px;
  border-bottom: 1px solid var(--border-hairline);
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: var(--bg-surface);
}
.hdr-utility .left,
.hdr-utility .right {
  display: flex;
  align-items: center;
  gap: 10px;
}
.hdr-utility .icon-btn {
  width: 40px; height: 40px;
  border-radius: 50%;
  background: var(--bg-surface);
  border: 1px solid var(--border-default);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--fg-strong);
}
.hdr-utility .icon-btn:hover { background: var(--zinc-100); }
.hdr-utility .icon-btn .ic { width: 16px; height: 16px; }

/* ─────────── Header — Row 2 (page-action) ─────────── */
.hdr-page {
  padding: 24px 32px 22px;
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: end;
  gap: 16px;
  background: var(--bg-surface);
  border-bottom: 1px solid var(--border-hairline);
}
.hdr-page .title { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
.hdr-page .title h1 {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: var(--t-display);
  line-height: 1;
  letter-spacing: -0.01em;
  margin: 0;
  color: var(--fg-strong);
}
.hdr-page .title .sub {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 14px;
  color: var(--fg-muted);
  line-height: 1;
}
.hdr-page .filters {
  display: inline-flex;
  align-items: center;
  background: var(--bg-surface);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-pill);
  padding: 4px;
  height: 40px;
  box-shadow: var(--shadow-card);
}
.hdr-page .filters button {
  height: 32px;
  padding: 0 16px;
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 13px;
  color: var(--fg-muted);
  white-space: nowrap;
}
.hdr-page .filters button.on { background: var(--zinc-950); color: #fff; }
.hdr-page .filters button.on.cancelled { background: var(--orange-500); }
.hdr-page .actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 10px;
  flex-wrap: wrap;
}

/* ─────────── Canvas (page content area) ─────────── */
.canvas {
  background: var(--bg-canvas);
  padding: 24px 32px 40px;
  display: flex;
  flex-direction: column;
  gap: 24px;
  flex: 1;
}

/* ─────────── Buttons ─────────── */
.btn {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  height: 40px;
  padding: 0 18px;
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 14px;
  line-height: 1;
  white-space: nowrap;
  box-shadow: var(--shadow-card);
  cursor: pointer;
  transition: background-color 120ms ease-out;
}
.btn-primary {
  background: var(--cyan-500);
  color: #fff;
}
.btn-primary:hover { background: var(--cyan-600); }
.btn-primary .ic { width: 14px; height: 14px; color: #fff; }
.btn-secondary {
  background: var(--bg-surface);
  color: var(--fg-strong);
  border: 1px solid var(--border-default);
}
.btn-secondary:hover { background: var(--zinc-100); }
.btn-icon {
  width: 40px; height: 40px;
  padding: 0;
  justify-content: center;
  background: var(--bg-surface);
  border: 1px solid var(--border-default);
  color: var(--fg-strong);
  box-shadow: var(--shadow-card);
}
.btn-icon:hover { background: var(--zinc-100); }
.btn-icon .ic { width: 16px; height: 16px; }
.btn-destructive {
  background: var(--rose-700);
  color: #fff;
}
.btn-destructive:hover { filter: brightness(1.08); }

/* ─────────── Status pill (§7.3 — single canonical primitive) ─────────── */
.pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  height: 24px;
  padding: 0 10px 0 8px;
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
  letter-spacing: 0.01em;
  white-space: nowrap;
}
.pill .dot {
  width: 6px; height: 6px;
  border-radius: 50%;
  background: currentColor;
  flex: none;
}
.pill .glyph {
  width: 12px; height: 12px;
  flex: none;
}
.pill-cream  { background: var(--amber-100); color: var(--amber-800); }
.pill-cyan   { background: var(--cyan-100);  color: var(--cyan-600); }
.pill-cyan-filled {
  background: var(--cyan-500);
  color: #fff;
}
.pill-cyan-filled .dot {
  background: #fff;
  box-shadow: 0 0 0 3px rgba(255, 255, 255, 0.28);
}
.pill-green  { background: var(--green-100); color: var(--green-700); }
.pill-rose   { background: var(--rose-100);  color: var(--rose-700); }
.pill-amber-warning {
  background: var(--amber-100);
  color: var(--amber-800);
}

/* ─────────── Count badge (§7.4) ─────────── */
.count-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  height: 18px;
  min-width: 22px;
  padding: 0 7px;
  background: var(--zinc-950);
  color: #fff;
  border-radius: var(--radius-pill);
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 11px;
  letter-spacing: 0.01em;
}

/* ─────────── Stat card (§7.5) ─────────── */
.stat-card {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  padding: 24px;
  display: flex;
  flex-direction: column;
  gap: 18px;
  min-width: 0;
}
.stat-card .meta {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--fg-muted);
  white-space: nowrap;
}
.stat-card .num {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: var(--t-display);
  line-height: 1;
  color: var(--fg-strong);
  font-feature-settings: 'tnum';
  display: flex;
  align-items: baseline;
  gap: 8px;
}
.stat-card .num .secondary {
  font-family: var(--font-ui);
  font-weight: 600;
  font-size: 14px;
  color: var(--fg-muted);
  letter-spacing: 0;
}
.stat-card.tone-green .num { color: var(--green-700); }
.stat-card.tone-cyan .num  { color: var(--cyan-500); }
.stat-card.tone-rose .num  { color: var(--rose-700); }

/* ─────────── Table (§7.9) ─────────── */
.tbl {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  width: 100%;
  border-collapse: collapse;
  overflow: hidden;
}
.tbl thead th {
  height: 48px;
  text-align: left;
  padding: 0 16px;
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: 10px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--fg-muted);
  border-bottom: 1px solid var(--border-hairline);
}
.tbl tbody td {
  height: 56px;
  padding: 0 16px;
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 14px;
  color: var(--fg-strong);
  border-bottom: 1px solid var(--border-hairline);
  vertical-align: middle;
}
.tbl tbody tr:hover { background: var(--zinc-50); }
.tbl tbody tr:last-child td { border-bottom: none; }
.tbl .meta {
  display: block;
  font-size: 12px;
  color: var(--fg-muted);
  font-weight: 600;
  margin-top: 2px;
}

/* ─────────── Cards (generic surface) ─────────── */
.card {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  padding: 24px;
}

/* ─────────── Centered auth card (login, logged_out) ─────────── */
.auth-page {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--bg-canvas);
  padding: 24px;
}
.auth-card {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-lg);
  padding: 32px;
  width: 100%;
  max-width: 400px;
  box-shadow: var(--shadow-card);
}
.auth-card h1 {
  font-family: var(--font-ui);
  font-weight: 800;
  font-size: var(--t-h1);
  line-height: 1;
  color: var(--fg-strong);
  margin: 0 0 8px;
}
.auth-card .sub {
  font-family: var(--font-tile);
  font-weight: 600;
  font-size: 14px;
  color: var(--fg-muted);
  margin: 0 0 24px;
}
.auth-card label {
  display: block;
  font-family: var(--font-ui);
  font-weight: 700;
  font-size: 12px;
  color: var(--fg-strong);
  margin: 0 0 6px;
}
.auth-card input[type="text"],
.auth-card input[type="email"],
.auth-card input[type="password"] {
  width: 100%;
  height: 40px;
  padding: 0 12px;
  border: 1px solid var(--border-default);
  border-radius: var(--radius-md);
  font-family: var(--font-ui);
  font-weight: 500;
  font-size: 14px;
  color: var(--fg-strong);
  margin-bottom: 16px;
  background: var(--bg-surface);
}
.auth-card input:focus {
  outline: none;
  border-color: var(--focus-ring);
}
.auth-card .btn-primary {
  width: 100%;
  justify-content: center;
}

/* ─────────── Toasts (Django messages) ─────────── */
.toasts {
  position: fixed;
  top: 16px;
  right: 16px;
  z-index: 1000;
  display: flex;
  flex-direction: column;
  gap: 8px;
  max-width: 360px;
}
.toast {
  background: var(--bg-card);
  border: 1px solid var(--border-hairline);
  border-radius: var(--radius-md);
  padding: 12px 16px;
  font-family: var(--font-ui);
  font-weight: 600;
  font-size: 13px;
  color: var(--fg-strong);
  box-shadow: var(--shadow-card);
  display: flex;
  align-items: center;
  gap: 8px;
}
.toast::before {
  content: "";
  display: inline-block;
  width: 8px; height: 8px;
  border-radius: 50%;
  background: var(--zinc-500);
  flex: none;
}
.toast.toast-success::before { background: var(--green-700); }
.toast.toast-info::before    { background: var(--cyan-500); }
.toast.toast-warning::before { background: var(--amber-800); }
.toast.toast-error::before   { background: var(--rose-700); }
```

- [ ] **Step 2: Verify the file is syntactically valid CSS**

```bash
wc -l static/css/shell.css
```

Expected: ~500–550 lines.

- [ ] **Step 3: Verify Django collects it**

```bash
python manage.py collectstatic --dry-run --noinput 2>&1 | grep shell.css
```

Expected: one line referencing `css/shell.css`.

- [ ] **Step 4: Commit**

```bash
git add static/css/shell.css
git commit -m "Foundation: add shell.css (sidebar, header, canvas, components)"
```

---

### Task 3: Create the three component partials

**Why:** These are the canonical primitives the spec defines. Building them now means screens written later import a shared template instead of reinventing the markup.

**Files:**
- Create: `voice/templates/voice/partials/status_pill.html`
- Create: `voice/templates/voice/partials/count_badge.html`
- Create: `voice/templates/voice/partials/stat_card.html`

- [ ] **Step 1: Create the partials directory**

```bash
mkdir -p voice/templates/voice/partials
```

- [ ] **Step 2: Write `voice/templates/voice/partials/status_pill.html`**

```django
{% comment %}
Status pill — §7.3 canonical primitive.

Usage:
  {% include "voice/partials/status_pill.html" with variant="cyan" label="Pre-Call" %}
  {% include "voice/partials/status_pill.html" with variant="green" label="Complete" glyph="check" %}

Parameters:
  variant — one of: cream, cyan, cyan-filled, green, rose, amber-warning
  label   — Title Case string
  glyph   — optional icon name; if set, renders 12px on the right INSTEAD of the left dot

Never both a dot and a glyph. The component enforces this by choosing one rendering branch.
{% endcomment %}
<span class="pill pill-{{ variant }}">
  {% if glyph %}
    <span class="label">{{ label }}</span>
    <span class="glyph ic ic-{{ glyph }}"></span>
  {% else %}
    <span class="dot"></span>
    <span class="label">{{ label }}</span>
  {% endif %}
</span>
```

- [ ] **Step 3: Write `voice/templates/voice/partials/count_badge.html`**

```django
{% comment %}
Count badge — §7.4.

Usage:
  {% include "voice/partials/count_badge.html" with count=12 %}

Renders nothing if count is 0 or falsy.
{% endcomment %}
{% if count %}<span class="count-badge">{{ count }}</span>{% endif %}
```

- [ ] **Step 4: Write `voice/templates/voice/partials/stat_card.html`**

```django
{% comment %}
Stat card — §7.5 canonical.

Usage:
  {% include "voice/partials/stat_card.html" with label="Active visits" value=7 tone="cyan" %}
  {% include "voice/partials/stat_card.html" with label="Complete" value=42 secondary="+6 wk" %}

Parameters:
  label     — string, rendered ALL CAPS via CSS
  value     — string or number
  tone      — optional: default | green | cyan | rose
  secondary — optional small inline value next to the number

NO sparklines, NO progress bars, NO right-side chips. Those belong in screen-specific cards.
{% endcomment %}
<div class="stat-card{% if tone and tone != 'default' %} tone-{{ tone }}{% endif %}">
  <div class="meta">{{ label }}</div>
  <div class="num">
    {{ value }}{% if secondary %}<span class="secondary">{{ secondary }}</span>{% endif %}
  </div>
</div>
```

- [ ] **Step 5: Verify partials parse**

```bash
python manage.py check
```

Expected: `System check identified no issues (0 silenced).` or similar — no template errors.

- [ ] **Step 6: Commit**

```bash
git add voice/templates/voice/partials/
git commit -m "Foundation: add status_pill, count_badge, stat_card partials"
```

---

### Task 4: Rewrite `voice/templates/voice/base.html`

**Why:** The whole foundation pass converges in this file. After this commit, every authenticated page renders inside the new shell.

**Files:**
- Modify: `voice/templates/voice/base.html` (full rewrite)

**Active-state URL-name table** (drives which sidebar row turns into the black pill):

| Sidebar row | Activates on `request.resolver_match.url_name` ∈ |
|---|---|
| Dashboard | `superuser_dashboard` |
| Visits | `visit_list`, `visit_detail` |
| Calendar | `visit_calendar` |
| Live Agent | `live_agent` |
| Agents | `agent_management`, `agent_add`, `agent_methodology` |
| Clients | `client_list`, `client_detail`, `client_create`, `client_edit`, `client_delete` |
| Methodologies | `methodology_list`, `methodology_create`, `methodology_edit` |
| Calls | `programmed_calls`, `manual_call_trigger` |
| Settings | `global_settings` |
| My Schedule (agent) | `sales_agent_dashboard` |
| Calendar Sync (agent) | `calendar_sync_status` |
| Profile (agent) | `sales_agent_profile` |

These URL names were cross-checked against `voice/urls.py` on 2026-05-26. If a future URL is added (e.g., a `visit_edit` view), update the table here and the corresponding `{% if %}` in `base.html`.

- [ ] **Step 1: Read the current `base.html` for reference**

```bash
cat voice/templates/voice/base.html | head -50
```

Note which `{% load %}` tags are present. The new file drops `{% load voice_tags %}` (no longer needed for DaisyUI filters) but keeps the option to re-add it later if other templates use other filters.

- [ ] **Step 2: Replace the entire file**

Write the file with this complete content:

```django
{% load static %}
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{% block title %}Sales Assistant{% endblock %}</title>

    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Nunito:wght@500;700;800&family=Nunito+Sans:wght@600;700&display=swap" rel="stylesheet">

    <link rel="stylesheet" href="{% static 'css/tokens.css' %}">
    <link rel="stylesheet" href="{% static 'css/icons.css' %}">
    <link rel="stylesheet" href="{% static 'css/shell.css' %}">

    {% block extra_css %}{% endblock %}
</head>
<body>

{% if user.is_authenticated %}
    <div class="app-shell">
        <aside class="sb">
            <div class="brand">
                <span class="mark">S</span>
                <div>
                    <div class="nm">Sales Assistant</div>
                    <div class="role">{% if user.is_superuser %}Manager{% elif user.is_sales_agent %}Sales Agent{% endif %}</div>
                </div>
            </div>

            {% if user.is_superuser %}
                <h4>Overview</h4>
                <div class="group">
                    <a href="{% url 'voice:superuser_dashboard' %}" class="row {% if request.resolver_match.url_name == 'superuser_dashboard' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-grid ic-18"></span></span>
                        <span class="label">Dashboard</span>
                    </a>
                    <a href="{% url 'voice:visit_list' %}" class="row {% if request.resolver_match.url_name == 'visit_list' or request.resolver_match.url_name == 'visit_detail' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-invite-alt ic-18"></span></span>
                        <span class="label">Visits</span>
                        {% include "voice/partials/count_badge.html" with count=unread_visits_count %}
                    </a>
                    <a href="{% url 'voice:visit_calendar' %}" class="row {% if request.resolver_match.url_name == 'visit_calendar' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-objects-column ic-18"></span></span>
                        <span class="label">Calendar</span>
                    </a>
                    <a href="{% url 'voice:live_agent' %}" class="row {% if request.resolver_match.url_name == 'live_agent' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-comment-alt-dots ic-18"></span></span>
                        <span class="label">Live Agent</span>
                    </a>
                </div>

                <h4>Manage</h4>
                <div class="group">
                    <a href="{% url 'voice:agent_management' %}" class="row {% if request.resolver_match.url_name == 'agent_management' or request.resolver_match.url_name == 'agent_add' or request.resolver_match.url_name == 'agent_methodology' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-id-badge ic-18"></span></span>
                        <span class="label">Agents</span>
                    </a>
                    <a href="{% url 'voice:client_list' %}" class="row {% if request.resolver_match.url_name == 'client_list' or request.resolver_match.url_name == 'client_detail' or request.resolver_match.url_name == 'client_create' or request.resolver_match.url_name == 'client_edit' or request.resolver_match.url_name == 'client_delete' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-grid ic-18"></span></span>
                        <span class="label">Clients</span>
                    </a>
                    <a href="{% url 'voice:methodology_list' %}" class="row {% if request.resolver_match.url_name == 'methodology_list' or request.resolver_match.url_name == 'methodology_create' or request.resolver_match.url_name == 'methodology_edit' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-grid ic-18"></span></span>
                        <span class="label">Methodologies</span>
                    </a>
                    <a href="{% url 'voice:programmed_calls' %}" class="row {% if request.resolver_match.url_name == 'programmed_calls' or request.resolver_match.url_name == 'manual_call_trigger' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-comment-alt-dots ic-18"></span></span>
                        <span class="label">Calls</span>
                    </a>
                </div>

                <div class="spacer"></div>

                <a href="{% url 'voice:global_settings' %}" class="row {% if request.resolver_match.url_name == 'global_settings' %}active{% endif %}">
                    <span class="iconslot"><span class="ic ic-menu-dots ic-18"></span></span>
                    <span class="label">Settings</span>
                </a>

            {% elif user.is_sales_agent %}
                <h4>Overview</h4>
                <div class="group">
                    <a href="{% url 'voice:sales_agent_dashboard' %}" class="row {% if request.resolver_match.url_name == 'sales_agent_dashboard' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-grid ic-18"></span></span>
                        <span class="label">My Schedule</span>
                    </a>
                    <a href="{% url 'voice:calendar_sync_status' %}" class="row {% if request.resolver_match.url_name == 'calendar_sync_status' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-objects-column ic-18"></span></span>
                        <span class="label">Calendar Sync</span>
                    </a>
                </div>

                <h4>Account</h4>
                <div class="group">
                    <a href="{% url 'voice:sales_agent_profile' %}" class="row {% if request.resolver_match.url_name == 'sales_agent_profile' %}active{% endif %}">
                        <span class="iconslot"><span class="ic ic-id-badge ic-18"></span></span>
                        <span class="label">Profile</span>
                    </a>
                </div>

                <div class="spacer"></div>
            {% endif %}

            <div class="me">
                <span class="av">{{ user.username|first|upper }}</span>
                <div>
                    <div class="nm">{{ user.get_full_name|default:user.username }}</div>
                    <div class="role"><a href="{% url 'voice:logout' %}">Logout</a></div>
                </div>
            </div>
        </aside>

        <div class="app-main">
            <div class="hdr-utility">
                <div class="left">{% block header_utility %}{% endblock %}</div>
                <div class="right">
                    <button class="icon-btn" type="button" aria-label="Search"><span class="ic ic-search ic-16"></span></button>
                    <button class="icon-btn" type="button" aria-label="Notifications"><span class="ic ic-comment-alt-dots ic-16"></span></button>
                </div>
            </div>

            <div class="hdr-page">
                <div class="title">
                    <h1>{% block display_title %}{% endblock %}</h1>
                    {% block display_subtitle %}{% endblock %}
                </div>
                <div class="filters-slot">{% block header_filters %}{% endblock %}</div>
                <div class="actions">{% block header_actions %}{% endblock %}</div>
            </div>

            {% if messages %}
            <div class="toasts">
                {% for message in messages %}
                <div class="toast toast-{{ message.tags|default:'info' }}">{{ message }}</div>
                {% endfor %}
            </div>
            {% endif %}

            <main class="canvas">
                {% block content %}{% endblock %}
            </main>
        </div>
    </div>

{% else %}
    <main class="auth-page">
        {% block unauth_content %}{% endblock %}
    </main>
{% endif %}

{% block extra_js %}{% endblock %}
</body>
</html>
```

- [ ] **Step 3: Run Django's template check**

```bash
python manage.py check
```

Expected: `System check identified no issues (0 silenced).`

- [ ] **Step 4: Start the dev server and visit `/` as a logged-in superuser**

```bash
python manage.py runserver 0.0.0.0:8003
```

In a browser, log in (or use an existing session) and navigate to `http://localhost:8003/`. Verify:
- 264px white sidebar on the left with the cyan "S" wordmark
- Sidebar shows two groups: "OVERVIEW" (Dashboard, Visits, Calendar, Live Agent) and "MANAGE" (Agents, Clients, Methodologies, Calls)
- "Settings" sits above the admin block at the bottom
- Admin block shows the user's first initial in a cyan circle and "Logout" as a small link
- Two-row header at the top of the content area
- No JavaScript console errors except possibly favicons (we haven't added a favicon)
- No 404s in the Network tab for `tokens.css`, `shell.css`, `icons.css`

- [ ] **Step 5: Stop the dev server**

Ctrl+C in the terminal running it.

- [ ] **Step 6: Commit**

```bash
git add voice/templates/voice/base.html
git commit -m "Foundation: rewrite base.html with new sidebar + header + role-aware nav"
```

---

### Task 5: Repaint `login.html`, `logged_out.html`, and `home.html`

**Why:** Without this, the unauthenticated branch renders an empty centered area (no styling on the login form) and `home.html` shows its Tailwind-styled card unstyled inside the new shell.

**Files:**
- Modify: `voice/templates/voice/login.html`
- Modify: `voice/templates/voice/logged_out.html`
- Modify: `voice/templates/voice/home.html`

**Form contract reference** (preserved from the current templates so the view code works unchanged):
- `login.html` uses a Django form with `form.username`, `form.password`, per-field error messages, `form.non_field_errors`, a `remember_me` checkbox, and `autofocus` on the username field. POST target is `{% url 'voice:login' %}`.
- `logged_out.html` is static — just a confirmation message + link to log in again.
- `home.html` is a thin authenticated landing — view sets no required context other than the implicit `user`.

- [ ] **Step 1: Rewrite `voice/templates/voice/login.html`**

Replace the entire file with:

```django
{% extends "voice/base.html" %}

{% block title %}Sign in — Sales Assistant{% endblock %}

{% block unauth_content %}
<div class="auth-card">
    <h1>Sign in</h1>
    <p class="sub">Sales Assistant — Manager console</p>

    {% if form.non_field_errors %}
        <div class="toast toast-error" style="margin-bottom:16px;">
            {% for error in form.non_field_errors %}<span>{{ error }}</span>{% endfor %}
        </div>
    {% endif %}

    <form method="post" action="{% url 'voice:login' %}">
        {% csrf_token %}

        <label for="{{ form.username.id_for_label }}">Username</label>
        <input
            type="text"
            name="{{ form.username.name }}"
            id="{{ form.username.id_for_label }}"
            value="{{ form.username.value|default:'' }}"
            autocomplete="username"
            required
            autofocus
        >
        {% if form.username.errors %}
            <p style="color:var(--rose-700);font-size:12px;font-weight:600;margin:-12px 0 12px;">{{ form.username.errors.0 }}</p>
        {% endif %}

        <label for="{{ form.password.id_for_label }}">Password</label>
        <input
            type="password"
            name="{{ form.password.name }}"
            id="{{ form.password.id_for_label }}"
            autocomplete="current-password"
            required
        >
        {% if form.password.errors %}
            <p style="color:var(--rose-700);font-size:12px;font-weight:600;margin:-12px 0 12px;">{{ form.password.errors.0 }}</p>
        {% endif %}

        <label style="display:flex;align-items:center;gap:8px;font-weight:500;cursor:pointer;margin-bottom:20px;">
            <input type="checkbox" name="remember_me" style="margin:0;">
            <span>Remember me</span>
        </label>

        <button type="submit" class="btn btn-primary">Sign in</button>
    </form>
</div>
{% endblock %}
```

- [ ] **Step 2: Rewrite `voice/templates/voice/logged_out.html`**

```django
{% extends "voice/base.html" %}

{% block title %}Signed out — Sales Assistant{% endblock %}

{% block unauth_content %}
<div class="auth-card">
    <h1>You've been signed out</h1>
    <p class="sub">Thanks for using Sales Assistant. See you next time.</p>
    <a href="{% url 'voice:login' %}" class="btn btn-primary">Sign in again</a>
</div>
{% endblock %}
```

- [ ] **Step 3: Rewrite `voice/templates/voice/home.html`**

```django
{% extends "voice/base.html" %}

{% block title %}Home — Sales Assistant{% endblock %}

{% block display_title %}Welcome, {{ user.get_full_name|default:user.username }}{% endblock %}

{% block content %}
<div class="card">
    <p class="t-body" style="margin:0 0 16px;">You're signed in to Sales Assistant.</p>
    <div style="display:flex;gap:8px;">
        {% if user.is_superuser %}
            <a class="btn btn-primary" href="{% url 'voice:superuser_dashboard' %}">Go to Dashboard</a>
        {% elif user.is_sales_agent %}
            <a class="btn btn-primary" href="{% url 'voice:sales_agent_dashboard' %}">Go to My Schedule</a>
        {% endif %}
        <a class="btn btn-secondary" href="{% url 'voice:logout' %}">Log out</a>
    </div>
</div>
{% endblock %}
```

Note: this keeps `home.html` as a thin landing page. The view itself isn't changed — if it sets context variables not used here, they remain set, just unused.

- [ ] **Step 4: Restart the dev server and verify each screen**

```bash
python manage.py runserver 0.0.0.0:8003
```

Then in a browser:
1. Log out, navigate to `http://localhost:8003/login/` — verify centered auth card on `--bg-canvas`, form fields styled with new tokens.
2. After logging in, navigate to `http://localhost:8003/` — verify the welcome card renders inside the new shell.
3. Log out — should land on `/logout/` or `/login/` (depends on `LOGOUT_REDIRECT_URL`); verify whichever appears uses the new styling.

- [ ] **Step 5: Stop the dev server**

Ctrl+C in the terminal.

- [ ] **Step 6: Commit**

```bash
git add voice/templates/voice/login.html voice/templates/voice/logged_out.html voice/templates/voice/home.html
git commit -m "Foundation: repaint login, logged_out, home with new design tokens"
```

---

### Task 6: Smoke-test verification across all routes

**Why:** Confirm the foundation actually works end-to-end before declaring it done. This is the verification gate from §7 of the spec.

**No files modified.** No commit. This task either passes or sends you back to fix something in Tasks 1–5.

- [ ] **Step 1: Start the dev server**

```bash
python manage.py runserver 0.0.0.0:8003
```

- [ ] **Step 2: Smoke checks as superuser**

In a browser, logged in as a superuser, visit each of these in turn. For each, the new sidebar + header must render; content area may look ugly (expected).

| URL | Expect active row |
|---|---|
| `/` (or whatever maps to `superuser_dashboard`) | Dashboard |
| `/visits/` | Visits |
| `/visit-calendar/` | Calendar |
| `/live-agent/` | Live Agent |
| `/agents/` | Agents |
| `/clients/` | Clients |
| `/methodologies/` | Methodologies |
| `/programmed-calls/` | Calls |
| `/settings/` | Settings |

(URLs may differ; use the project's actual paths from `voice/urls.py`.)

Check in browser DevTools:
- **Network tab:** `tokens.css`, `shell.css`, `icons.css` all return 200 (not 404).
- **Network tab:** `fonts.googleapis.com` and `fonts.gstatic.com` requests succeed; Nunito and Nunito Sans appear in the font list.
- **Computed styles** on the sidebar `.nm` element: `font-family` is `Nunito`, NOT a system fallback.
- **Console:** no JavaScript errors (favicon 404 is OK).

- [ ] **Step 3: Smoke checks as sales agent**

Log out, log back in as a sales-agent user. Verify:
- Sidebar shows "OVERVIEW" with "My Schedule" + "Calendar Sync"
- Sidebar shows "ACCOUNT" with "Profile"
- No "MANAGE" group
- No "Settings" row at the bottom
- Admin block at bottom shows the agent's initial and name

Click each agent nav row, confirm active state turns the row into the black pill.

- [ ] **Step 4: Smoke checks unauthenticated**

Log out completely. Visit `/login/`:
- Centered auth card on `--bg-canvas`
- "Sign in" heading in Nunito 800
- Form fields with hairline borders
- Cyan "Sign in" primary button

- [ ] **Step 5: Toast/messages check**

Trigger a Django message — e.g., submit the login form with bad credentials, or any flow that calls `messages.add_message`. Verify:
- Toast appears top-right
- Background is white, hairline border, color-keyed dot on the left
- Disappears on next navigation (no auto-dismiss yet; that's a later concern)

- [ ] **Step 6: Expected-ugly check (NOT a bug)**

Visit a screen that wasn't redesigned, e.g., `/clients/` or `/agents/`. Confirm:
- Sidebar and header render correctly (new design)
- Content area inside `.canvas` shows bare unstyled HTML with no Tailwind classes taking effect — this is the agreed transition cost. Do not file a bug.

- [ ] **Step 7: Stop the dev server**

Ctrl+C.

- [ ] **Step 8: Self-attest the foundation pass is complete**

If every smoke check above passed, the foundation is done. If any failed:
- 404 on a CSS file → check `STATICFILES_DIRS` and the file path under `static/`.
- Sidebar doesn't render → check the `{% if user.is_authenticated %}` branch in `base.html`.
- Active state never turns on → check `request.resolver_match.url_name` matches one of the names in the active-state table in Task 4.
- Fonts fall back to system → check the Google Fonts link tag and `fonts.googleapis.com` access in DevTools.
- Static file 404 in production-like mode → run `python manage.py collectstatic` (this pass uses dev-mode serving).

No commit for this task. The foundation is done when all smoke checks pass on the existing commits from Tasks 1–5.

---

## Out of scope for this plan (do not implement)

- Any screen redesign (Dashboard content, Visits list, Visit Detail, Calendar, Live Agent, Calls, Clients, Agents, Methodologies). Each gets its own plan in a later pass.
- Mobile layout. Spec says secondary; no investment.
- Notifications popover or search modal — header buttons are placeholders.
- Profile dropdown — admin block "Logout" is a direct link.
- Removing `voice_tags` template tag library or its `daisyui_alert_class` filter. Other templates may still load it; safer to leave it in place even though the new `base.html` doesn't use it.
- Cleaning up Tailwind class names in un-redesigned templates. They render as dead string content with no effect; we leave them until each screen is redesigned.
- Adding Django tests for template rendering. This pass is pure visual chrome; verification is manual.

---

## Rollback

This is a clean revert. Each task is a single commit. To roll the entire pass back:

```bash
git log --oneline | head -10                # find the commits from Tasks 1–5
git revert <task5-commit> <task4-commit> <task3-commit> <task2-commit> <task1-commit>
```

No database migrations, no service changes, no environment variable changes. Pure template + static asset rollback.
