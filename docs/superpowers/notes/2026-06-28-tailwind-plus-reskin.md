# Tailwind Plus re-skin — progress tracker

Re-skinning every screen using the local Tailwind Plus (Application UI) component
library. Multi-session effort; this file is the source of truth for what's done.

## Source library (local, never committed)
- Root: `/Users/alex/Code/tailwindui/output/html/ui-blocks/application-ui`
- Catalog: `/Users/alex/Code/tailwindui/INDEX.md` (+ `components.json`)
- Previews: `/Users/alex/Code/tailwindui/output/preview/…`

## Decisions (locked 2026-06-28)
- **Dark mode:** one-line enabler. `@custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *));`
  in `app.css` so TW Plus `dark:` classes follow the app's theme toggle. We adopt the
  **TW Plus look** (gray/white/indigo palette) instead of remapping to `base-*` tokens.
- **Order:** shared shell + shared widgets FIRST, then page by page.
- **Sidebar:** light "sidebar with header" (`application-shells/sidebar/sidebar_with_header.html`).

## Conversion rules
- Plain HTML → HEEx: keep `class=`, swap content for assigns/`{...}`, use `hero-*` icons.
- STRIP TW Plus "Elements" web components (`<el-dropdown>`, `commandfor`, popover, the
  script loader). Use LiveView `JS.toggle/show/hide` + `phx-click` + core `<.modal>`.
- Build: `mix assets.build`; verify `mix compile --warnings-as-errors`.

## Foundation — DONE
- [x] `@custom-variant dark` added to `app.css`
- [x] Shell re-skinned (`layouts.ex` `agent_app` + `sidebar` + `nav_item`, light palette)
- [x] `root.html.heex` body → `bg-white dark:bg-gray-900 text-gray-900 dark:text-white`

## Shared widgets — `lib/florina_web/components/core_components.ex` (TODO)
Re-skin once, benefits every page. Check the catalog for each:
- [x] buttons (`elements/buttons`)
- [x] form inputs / selects / textareas (`forms/*`)
- [x] tables (`lists/tables`)
- [x] cards / list containers (`layout/cards`, `lists/stacked-lists`)
- [x] badges / pills (`elements/badges`)
- [ ] modal (`overlays/modal-dialogs`)
- [x] flash / alerts (`feedback/alerts`)
- [x] headings (`headings/page-headings`, `headings/section-headings`)

## Pages — `lib/florina_web/live/` (TODO, one by one)
Manager:
- [x] manage/dashboard_live
- [x] manage/meetings_live
- [x] manage/meeting_live (detail)
- [x] manage/meeting_form_live (new/edit)
- [x] manage/calls_live (programmed calls)
- [x] manage/clients_live
- [x] manage/client_live (detail)
- [x] manage/agents_live (people)
- [x] manage/methodologies_live
- [ ] manage/mega_prompts_live
- [ ] manage/generation_runs_live
- [ ] manage/settings_live
- [ ] manage/logs_live
- [ ] chat_live (assistant, manager-only)

Agent:
- [ ] agent_today_live (My Day)
- [ ] calls_live (call-me)
- [ ] calendar_live (shared manager+agent)
- [ ] clients_live (agent client directory)

Admin / other:
- [ ] admin/index_live
- [ ] admin/tenants_live
- [ ] admin/agents_live
- [ ] admin/config_live
- [ ] tenant_chat_live

Auth/standalone (use `Layouts.app`, not the agent shell) — revisit:
- [ ] login / logged-out / home (controller-rendered)
- [ ] `Layouts.app` (the non-agent shell)
