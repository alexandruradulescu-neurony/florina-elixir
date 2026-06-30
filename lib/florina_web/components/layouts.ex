defmodule FlorinaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use FlorinaWeb, :html

  alias Florina.Authz

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="flex items-center justify-between border-b border-gray-200 bg-white px-4 py-3 sm:px-6 lg:px-8 dark:border-white/10 dark:bg-gray-900">
      <a href="/" class="text-lg font-semibold text-gray-900 dark:text-white">Florina</a>
      <.theme_toggle />
    </header>

    <main class="mx-auto max-w-6xl px-4 py-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Authenticated agent app shell: responsive sidebar (desktop fixed + mobile
  off-canvas) + sticky top bar + content slot. Adapted from a Tailwind Plus
  application-shell — Elements web components replaced with LiveView `JS`,
  colors mapped to the project's `base-*`/`primary` theme tokens.

      <Layouts.agent_app flash={@flash} tenant={@tenant} current_agent={@current_agent} active={:calendar}>
        <h1>Content</h1>
      </Layouts.agent_app>
  """
  attr :flash, :map, required: true
  attr :tenant, :map, required: true, doc: "the resolved tenant (has :slug, :name)"
  attr :current_agent, :map, default: nil, doc: "the signed-in agent user"
  attr :active, :atom, default: nil, doc: ":calendar | :calls | :chat — highlights the nav item"
  slot :inner_block, required: true

  def agent_app(assigns) do
    ~H"""
    <%!-- Mobile off-canvas sidebar (toggled by JS; hidden on lg+) --%>
    <div id="mobile-sidebar" class="relative z-50 hidden lg:hidden" role="dialog" aria-modal="true">
      <div class="fixed inset-0 bg-gray-900/80" phx-click={hide_mobile_sidebar()} aria-hidden="true" />
      <div class="fixed inset-0 flex">
        <div class="relative mr-16 flex w-full max-w-xs flex-1">
          <div class="absolute top-0 left-full flex w-16 justify-center pt-5">
            <button type="button" phx-click={hide_mobile_sidebar()} class="-m-2.5 p-2.5">
              <span class="sr-only">Close sidebar</span>
              <.icon name="hero-x-mark" class="size-6 text-white" />
            </button>
          </div>
          <.sidebar tenant={@tenant} active={@active} manager?={Authz.manager?(@current_agent)} />
        </div>
      </div>
    </div>

    <%!-- Desktop sidebar (fixed) --%>
    <div class="hidden lg:fixed lg:inset-y-0 lg:z-50 lg:flex lg:w-72 lg:flex-col">
      <.sidebar tenant={@tenant} active={@active} manager?={Authz.manager?(@current_agent)} />
    </div>

    <div class="lg:pl-72">
      <%!-- Top bar --%>
      <div class="sticky top-0 z-40 flex h-16 shrink-0 items-center gap-x-4 border-b border-gray-200 bg-white px-4 shadow-xs sm:gap-x-6 sm:px-6 lg:px-8 dark:border-white/10 dark:bg-gray-900 dark:shadow-none">
        <button
          type="button"
          phx-click={show_mobile_sidebar()}
          class="-m-2.5 p-2.5 text-gray-700 hover:text-gray-900 lg:hidden dark:text-gray-400 dark:hover:text-white"
        >
          <span class="sr-only">Open sidebar</span>
          <.icon name="hero-bars-3" class="size-6" />
        </button>
        <div aria-hidden="true" class="h-6 w-px bg-gray-200 lg:hidden dark:bg-white/10" />

        <div class="flex flex-1 items-center justify-end gap-x-4 self-stretch lg:gap-x-6">
          <.theme_toggle />
          <div
            aria-hidden="true"
            class="hidden lg:block lg:h-6 lg:w-px lg:bg-gray-200 dark:lg:bg-white/10"
          />

          <%!-- User menu --%>
          <div class="relative">
            <button
              type="button"
              phx-click={JS.toggle(to: "#user-menu")}
              class="flex items-center gap-x-2"
            >
              <span class="sr-only">Open user menu</span>
              <span class="flex size-8 items-center justify-center rounded-full bg-indigo-500 text-sm font-bold text-white">
                {agent_initial(@current_agent)}
              </span>
              <span class="hidden lg:flex lg:items-center">
                <span class="text-sm font-semibold text-gray-900 dark:text-white">{agent_name(
                  @current_agent
                )}</span>
                <.icon name="hero-chevron-down" class="ml-1 size-5 text-gray-400 dark:text-gray-500" />
              </span>
            </button>
            <div
              id="user-menu"
              phx-click-away={JS.hide(to: "#user-menu")}
              class="absolute right-0 z-10 mt-2 hidden w-44 origin-top-right rounded-md bg-white py-2 shadow-lg outline-1 outline-gray-900/5 dark:bg-gray-800 dark:shadow-none dark:outline-white/10"
            >
              <div class="truncate border-b border-gray-200 px-3 pb-2 text-xs text-gray-500 dark:border-white/10 dark:text-gray-400">
                {agent_email(@current_agent)}
              </div>
              <.link
                href={"/t/#{@tenant.slug}/logout"}
                method="delete"
                class="block px-3 py-1.5 text-sm text-gray-900 hover:bg-gray-50 dark:text-white dark:hover:bg-white/5"
              >
                Sign out
              </.link>
            </div>
          </div>
        </div>
      </div>

      <main class="px-4 py-8 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-6xl">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  # Sidebar inner (shared by the desktop + mobile variants).
  attr :tenant, :map, required: true
  attr :active, :atom, default: nil
  attr :manager?, :boolean, default: false

  defp sidebar(assigns) do
    ~H"""
    <div class="flex grow flex-col gap-y-5 overflow-y-auto border-r border-gray-200 bg-white px-6 pb-4 dark:border-white/10 dark:bg-gray-900">
      <div class="flex h-16 shrink-0 items-center gap-x-3">
        <span class="flex size-9 items-center justify-center rounded-[10px] bg-indigo-500 text-base font-extrabold text-white">
          F
        </span>
        <span class="text-base font-extrabold tracking-tight text-gray-900 dark:text-white">Florina</span>
      </div>
      <nav class="flex flex-1 flex-col">
        <ul role="list" class="flex flex-1 flex-col gap-y-7">
          <li>
            <div class="mt-1 text-[10px] font-extrabold uppercase tracking-[0.1em] text-gray-500">
              {@tenant.name}
            </div>
            <ul role="list" class="-mx-2 mt-2 space-y-1">
              <.nav_item
                label="Calendar"
                icon="hero-calendar"
                href={"/t/#{@tenant.slug}/calendar"}
                active={@active == :calendar}
              />
              <.nav_item
                :if={!@manager?}
                label="Calls"
                icon="hero-phone"
                href={"/t/#{@tenant.slug}/calls"}
                active={@active == :calls}
              />
              <.nav_item
                :if={!@manager?}
                label="Today"
                icon="hero-sun"
                href={"/t/#{@tenant.slug}/today"}
                active={@active == :today}
              />
              <.nav_item
                :if={!@manager?}
                label="Clients"
                icon="hero-building-office-2"
                href={"/t/#{@tenant.slug}/clients"}
                active={@active == :clients}
              />
              <.nav_item
                :if={@manager?}
                label="Assistant"
                icon="hero-chat-bubble-left-right"
                href={"/t/#{@tenant.slug}/chat"}
                active={@active == :chat}
              />
            </ul>
          </li>
          <li :if={@manager?}>
            <div class="mt-1 text-[10px] font-extrabold uppercase tracking-[0.1em] text-gray-500">
              Management
            </div>
            <ul role="list" class="-mx-2 mt-2 space-y-1">
              <.nav_item
                label="Dashboard"
                icon="hero-chart-bar"
                href={"/t/#{@tenant.slug}/manage/dashboard"}
                active={@active == :dashboard}
              />
              <.nav_item
                label="Meetings"
                icon="hero-briefcase"
                href={"/t/#{@tenant.slug}/manage/meetings"}
                active={@active == :meetings}
              />
              <.nav_item
                label="Calls"
                icon="hero-phone"
                href={"/t/#{@tenant.slug}/manage/calls"}
                active={@active == :programmed_calls}
              />
              <.nav_item
                label="Clients"
                icon="hero-building-office-2"
                href={"/t/#{@tenant.slug}/manage/clients"}
                active={@active == :clients}
              />
              <.nav_item
                label="People"
                icon="hero-users"
                href={"/t/#{@tenant.slug}/manage/agents"}
                active={@active == :agents}
              />
              <.nav_item
                label="Methodologies"
                icon="hero-academic-cap"
                href={"/t/#{@tenant.slug}/manage/methodologies"}
                active={@active == :methodologies}
              />
              <.nav_item
                label="Mega Prompts"
                icon="hero-sparkles"
                href={"/t/#{@tenant.slug}/manage/mega-prompts"}
                active={@active == :mega_prompts}
              />
              <.nav_item
                label="Generation Runs"
                icon="hero-clipboard-document-list"
                href={"/t/#{@tenant.slug}/manage/generation-runs"}
                active={@active == :generation_runs}
              />
              <.nav_item
                label="Settings"
                icon="hero-cog-6-tooth"
                href={"/t/#{@tenant.slug}/manage/settings"}
                active={@active == :settings}
              />
              <.nav_item
                label="Logs"
                icon="hero-document-text"
                href={"/t/#{@tenant.slug}/manage/logs"}
                active={@active == :logs}
              />
            </ul>
          </li>
        </ul>
      </nav>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :href, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <li>
      <.link
        navigate={@href}
        class={[
          "group flex gap-x-3 rounded-md p-2 text-sm/6 font-bold",
          (@active && "bg-zinc-950 text-white dark:bg-indigo-600") ||
            "text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-white/5"
        ]}
      >
        <.icon
          name={@icon}
          class={[
            "size-6 shrink-0",
            (@active && "text-white") ||
              "text-gray-400 dark:text-gray-500"
          ]}
        />
        {@label}
      </.link>
    </li>
    """
  end

  defp show_mobile_sidebar(js \\ %JS{}), do: JS.show(js, to: "#mobile-sidebar")
  defp hide_mobile_sidebar(js \\ %JS{}), do: JS.hide(js, to: "#mobile-sidebar")

  defp agent_name(%{first_name: f, last_name: l} = a)
       when is_binary(f) or is_binary(l) do
    case [f, l] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> agent_email(a)
      name -> name
    end
  end

  defp agent_name(a), do: agent_email(a)

  defp agent_email(%{email: e}) when is_binary(e) and e != "", do: e
  defp agent_email(%{username: u}) when is_binary(u) and u != "", do: u
  defp agent_email(_), do: "Agent"

  defp agent_initial(a) do
    a |> agent_name() |> String.first() |> Kernel.||("A") |> String.upcase()
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border border-base-300 bg-base-200">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
