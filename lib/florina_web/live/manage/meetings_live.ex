defmodule FlorinaWeb.Manage.MeetingsLive do
  @moduledoc """
  Manager meetings board — a live, timeline-grouped view of every meeting (Visit)
  across the team. Answers "what's coming up, what's happening now, and what needs
  me?" at a glance.

  Meetings are bucketed into Now / Today / Upcoming / Earlier; each row carries a
  connected pre-call → meeting → post-call progress track derived from its call
  attempts. The board subscribes to the tenant's call feed and re-buckets on a
  1-minute tick, so status and relative times stay current without a refresh.
  Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Accounts, Calls, Settings, Visits}

  @tick_ms 60_000
  @default_filters %{"range" => "week", "agent_id" => "", "status" => "", "florina" => ""}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Florina.PubSub, Calls.topic(socket.assigns.tenant.slug))
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign(:agents, Accounts.list_agents())
     |> assign(:filters, @default_filters)
     |> assign(:show_earlier, false)
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket),
    do: {:noreply, socket |> assign(:filters, Map.merge(@default_filters, filters)) |> load()}

  def handle_event("clear", _params, socket),
    do: {:noreply, socket |> assign(:filters, @default_filters) |> load()}

  def handle_event("show_all", _params, socket),
    do:
      {:noreply,
       socket |> assign(:filters, Map.put(socket.assigns.filters, "range", "all")) |> load()}

  def handle_event("toggle_earlier", _params, socket),
    do: {:noreply, update(socket, :show_earlier, &(!&1))}

  # A call changed (webhook/dial) — re-query so the row's progress track and the
  # counts stay exact.
  @impl true
  def handle_info({:call_updated, _call}, socket), do: {:noreply, load(socket)}

  # Periodic re-bucket so "now" advances and relative times stay fresh.
  def handle_info(:tick, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)
    {:noreply, load(socket)}
  end

  defp load(socket) do
    now = DateTime.utc_now()
    today = DateTime.to_date(Florina.Tz.local(now))
    sys_default = Settings.get().default_methodology_id
    visits = Visits.list_for_manager_board(socket.assigns.filters)
    buckets = bucketize(visits, now, today)
    attention = attention_items(visits, sys_default)

    socket
    |> assign(:now, now)
    |> assign(:buckets, buckets)
    |> assign(:attention, attention)
    |> assign(:has_meetings, visits != [])
    |> assign(:stats, %{
      today: Enum.count(visits, &same_day?(&1.start_time, today)),
      upcoming: Enum.count(visits, &future_day?(&1.start_time, today)),
      in_progress: length(buckets.now),
      attention: length(attention)
    })
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:meetings}
    >
      <.header micro="Manage">
        Meetings
        <:subtitle>Live status of every meeting across your team.</:subtitle>
        <:actions>
          <.button navigate={"/t/#{@tenant.slug}/manage/meetings/new"} variant="primary">
            <.icon name="hero-plus" class="size-4" /> New meeting
          </.button>
        </:actions>
      </.header>

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4 mb-6">
        <.stat_card label="Today" tone="neutral">{@stats.today}</.stat_card>
        <.stat_card label="Upcoming" tone="blue">{@stats.upcoming}</.stat_card>
        <.stat_card label="In progress" tone="cyan">{@stats.in_progress}</.stat_card>
        <.stat_card label="Needs attention" tone="rose">{@stats.attention}</.stat_card>
      </div>

      <section :if={@attention != []} class="mb-6">
        <h2 class="mb-2 text-[11px] font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400">
          Needs attention
        </h2>
        <ul class="space-y-2">
          <.link
            :for={item <- @attention}
            navigate={"/t/#{@tenant.slug}/manage/meetings/#{item.visit_id}"}
            class={[
              "flex items-center gap-2 rounded-lg border px-3 py-2 text-sm text-gray-700 dark:text-gray-300",
              (item.severity == :error &&
                 "border-red-200 bg-red-50 hover:bg-red-100 dark:border-red-500/20 dark:bg-red-500/10") ||
                "border-amber-200 bg-amber-50 hover:bg-amber-100 dark:border-amber-500/20 dark:bg-amber-500/10"
            ]}
          >
            <.icon
              name="hero-exclamation-triangle"
              class={[
                "size-4 shrink-0",
                (item.severity == :error && "text-red-500") || "text-amber-500"
              ]}
            />
            <span class="truncate">{item.message}</span>
          </.link>
        </ul>
      </section>

      <.form
        for={%{}}
        as={:filters}
        id="meetings-filter-form"
        phx-change="filter"
        class="flex flex-wrap items-end gap-3 mb-6"
      >
        <label class="text-sm">
          <span class="mb-1 block text-xs text-gray-500 dark:text-gray-400">Range</span>
          <select name="filters[range]" class={filter_select()}>
            <option value="today" selected={@filters["range"] == "today"}>Today</option>
            <option value="week" selected={@filters["range"] == "week"}>This week</option>
            <option value="all" selected={@filters["range"] == "all"}>All</option>
          </select>
        </label>
        <label class="text-sm">
          <span class="mb-1 block text-xs text-gray-500 dark:text-gray-400">Agent</span>
          <select name="filters[agent_id]" class={filter_select()}>
            <option value="" selected={@filters["agent_id"] == ""}>All</option>
            <option
              :for={a <- @agents}
              value={a.id}
              selected={@filters["agent_id"] == to_string(a.id)}
            >
              {agent_label(a)}
            </option>
          </select>
        </label>
        <label class="text-sm">
          <span class="mb-1 block text-xs text-gray-500 dark:text-gray-400">Status</span>
          <select name="filters[status]" class={filter_select()}>
            <option value="" selected={@filters["status"] == ""}>All</option>
            <option
              :for={{label, value} <- status_options()}
              value={value}
              selected={@filters["status"] == value}
            >
              {label}
            </option>
          </select>
        </label>
        <label class="text-sm">
          <span class="mb-1 block text-xs text-gray-500 dark:text-gray-400">Florina</span>
          <select name="filters[florina]" class={filter_select()}>
            <option value="" selected={@filters["florina"] == ""}>All</option>
            <option value="on" selected={@filters["florina"] == "on"}>Calls on</option>
            <option value="off" selected={@filters["florina"] == "off"}>Calls off</option>
          </select>
        </label>
        <button
          type="button"
          phx-click="clear"
          class="rounded-md px-3 py-1.5 text-sm font-semibold text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-white/10"
        >
          Clear
        </button>
      </.form>

      <div :if={@has_meetings} class="space-y-8">
        <%!-- NOW — the loud, accented bucket --%>
        <section :if={@buckets.now != []}>
          <div class="mb-3 flex items-center gap-2">
            <span class="relative flex size-2.5">
              <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-indigo-400 opacity-75" />
              <span class="relative inline-flex size-2.5 rounded-full bg-indigo-500" />
            </span>
            <h2 class="text-[11px] font-extrabold uppercase tracking-[0.1em] text-indigo-600 dark:text-indigo-400">
              Now
            </h2>
            <span class="text-[11px] font-bold text-gray-400">{length(@buckets.now)}</span>
          </div>
          <div class="overflow-hidden rounded-lg border border-indigo-200 bg-white divide-y divide-gray-100 dark:border-indigo-500/30 dark:bg-white/5 dark:divide-white/5">
            <.meeting_row :for={v <- @buckets.now} v={v} now={@now} slug={@tenant.slug} kind={:now} />
          </div>
        </section>

        <.bucket_section
          :if={@buckets.today != []}
          label="Today"
          meetings={@buckets.today}
          now={@now}
          slug={@tenant.slug}
          kind={:today}
        />
        <.bucket_section
          :if={@buckets.upcoming != []}
          label="Upcoming"
          meetings={@buckets.upcoming}
          now={@now}
          slug={@tenant.slug}
          kind={:upcoming}
        />

        <%!-- EARLIER — quieted + collapsed by default so live work wins the eye --%>
        <section :if={@buckets.earlier != []}>
          <button
            type="button"
            phx-click="toggle_earlier"
            class="mb-3 flex items-center gap-2 text-gray-400 hover:text-gray-600 dark:hover:text-gray-300"
          >
            <.icon
              name="hero-chevron-right"
              class={["size-3.5 transition-transform", @show_earlier && "rotate-90"]}
            />
            <h2 class="text-[11px] font-extrabold uppercase tracking-[0.1em]">Earlier</h2>
            <span class="text-[11px] font-bold">{length(@buckets.earlier)}</span>
          </button>
          <div
            :if={@show_earlier}
            class="overflow-hidden rounded-lg border border-gray-200 bg-white divide-y divide-gray-100 dark:border-white/10 dark:bg-white/5 dark:divide-white/5"
          >
            <.meeting_row
              :for={v <- @buckets.earlier}
              v={v}
              now={@now}
              slug={@tenant.slug}
              kind={:earlier}
            />
          </div>
        </section>
      </div>

      <%!-- Empty state — a calm, designed moment, not blank space --%>
      <div
        :if={!@has_meetings}
        class="rounded-lg border border-dashed border-gray-300 px-6 py-16 text-center dark:border-white/15"
      >
        <.icon name="hero-calendar-days" class="mx-auto size-10 text-gray-300 dark:text-gray-600" />
        <p class="mt-3 text-sm font-bold text-gray-900 dark:text-white">
          {empty_title(@filters["range"])}
        </p>
        <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
          Meetings appear here automatically as your calendar syncs, or add one by hand.
        </p>
        <div class="mt-5 flex items-center justify-center gap-3">
          <.button navigate={"/t/#{@tenant.slug}/manage/meetings/new"} variant="primary">
            <.icon name="hero-plus" class="size-4" /> New meeting
          </.button>
          <button
            :if={@filters["range"] != "all"}
            type="button"
            phx-click="show_all"
            class="text-sm font-bold text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
          >
            View all meetings
          </button>
        </div>
      </div>
    </Layouts.agent_app>
    """
  end

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  attr :label, :string, required: true
  attr :meetings, :list, required: true
  attr :now, DateTime, required: true
  attr :slug, :string, required: true
  attr :kind, :atom, required: true

  defp bucket_section(assigns) do
    ~H"""
    <section>
      <div class="mb-3 flex items-center gap-2">
        <h2 class="text-[11px] font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400">
          {@label}
        </h2>
        <span class="text-[11px] font-bold text-gray-400">{length(@meetings)}</span>
      </div>
      <div class="overflow-hidden rounded-lg border border-gray-200 bg-white divide-y divide-gray-100 dark:border-white/10 dark:bg-white/5 dark:divide-white/5">
        <.meeting_row :for={v <- @meetings} v={v} now={@now} slug={@slug} kind={@kind} />
      </div>
    </section>
    """
  end

  attr :v, :map, required: true
  attr :now, DateTime, required: true
  attr :slug, :string, required: true
  attr :kind, :atom, required: true

  defp meeting_row(assigns) do
    ~H"""
    <.link
      navigate={"/t/#{@slug}/manage/meetings/#{@v.id}"}
      class={["group block px-4 py-3 transition-colors", row_class(@kind)]}
    >
      <div class="grid grid-cols-1 gap-4 lg:grid-cols-[minmax(0,1.6fr)_auto_minmax(0,1fr)] lg:items-center">
        <%!-- Primary → secondary → tertiary, ranked by weight and color --%>
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <span class={["truncate font-bold", title_class(@kind)]}>{@v.title}</span>
            <.florina_badge :if={!@v.calls_enabled} />
            <span
              :if={@kind == :earlier and terminal?(@v.status)}
              class={["rounded-full px-2 py-0.5 text-[11px] font-semibold", status_tone(@v.status)]}
            >
              {status_label(@v.status)}
            </span>
          </div>
          <div class={["mt-0.5 flex items-center gap-2 font-tile text-sm", time_class(@kind)]}>
            <span class="tabular-nums">{clock(@now, @v.start_time)}</span>
            <span class="text-gray-400">·</span>
            <span>{time_phrase(@now, @v, @kind)}</span>
          </div>
          <div class="mt-0.5 truncate text-sm text-gray-500 dark:text-gray-400">
            {client_label(@v.client)} · {agent_label(@v.agent)}
          </div>
          <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px] text-gray-400 dark:text-gray-500">
            <span class="inline-flex items-center gap-1">
              <.icon name={provider_icon(@v.provider)} class="size-3.5" />{provider_label(@v.provider)}
            </span>
            <span :if={methodology_label(@v)} class="inline-flex items-center gap-1">
              <span aria-hidden="true">·</span>{methodology_label(@v)}
            </span>
            <span :if={@v.crm_synced} class="inline-flex items-center gap-1">
              <span aria-hidden="true">·</span>
              <.icon name="hero-arrow-path-rounded-square" class="size-3.5" /> CRM
            </span>
          </div>
        </div>

        <%!-- Hero: the connected pre → meeting → post track, aligned per row --%>
        <.progress_track
          pre={pre_status(@v)}
          meeting={meeting_status(@v, @now)}
          post={post_status(@v)}
        />

        <%!-- Last-call context + a hover affordance toward the detail cockpit --%>
        <div class="flex items-center gap-2 min-w-0">
          <p class="min-w-0 flex-1 truncate text-sm text-gray-500 dark:text-gray-400">
            {last_summary(@v)}
          </p>
          <.icon
            name="hero-chevron-right"
            class="size-4 shrink-0 text-gray-300 group-hover:text-gray-500 dark:text-gray-600 dark:group-hover:text-gray-300"
          />
        </div>
      </div>
    </.link>
    """
  end

  attr :pre, :atom, required: true
  attr :meeting, :atom, required: true
  attr :post, :atom, required: true

  defp progress_track(assigns) do
    ~H"""
    <div
      class="flex items-center justify-center lg:justify-start"
      role="group"
      aria-label="Call progress"
    >
      <.phase_node status={@pre} label="Pre" />
      <.connector filled={@pre in [:done, :failed]} />
      <.phase_node status={@meeting} label="Meet" />
      <.connector filled={@meeting == :done} />
      <.phase_node status={@post} label="Post" />
    </div>
    """
  end

  attr :status, :atom, required: true
  attr :label, :string, required: true

  defp phase_node(assigns) do
    ~H"""
    <div class="flex w-12 flex-col items-center gap-1">
      <span class={["flex size-7 items-center justify-center rounded-full", node_bg(@status)]}>
        <.icon
          name={node_icon(@status)}
          class={["size-4", node_fg(@status), @status == :live && "motion-safe:animate-spin"]}
        />
      </span>
      <span class={["text-[10px] font-bold uppercase tracking-wide", node_label_class(@status)]}>
        {@label}
      </span>
    </div>
    """
  end

  attr :filled, :boolean, required: true

  defp connector(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "mx-1 mb-4 h-0.5 w-5 rounded sm:w-8",
        (@filled && "bg-green-300 dark:bg-green-500/40") || "bg-gray-200 dark:bg-white/10"
      ]}
    />
    """
  end

  defp florina_badge(assigns) do
    ~H"""
    <span class="inline-flex shrink-0 items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[11px] font-semibold text-amber-700 dark:bg-amber-500/15 dark:text-amber-400">
      <.icon name="hero-phone-x-mark" class="size-3" /> Calls off
    </span>
    """
  end

  # ---------------------------------------------------------------------------
  # Bucketing + attention (the page's "story")
  # ---------------------------------------------------------------------------

  defp bucketize(visits, now, today) do
    grouped = Enum.group_by(visits, &bucket_of(&1, now, today))

    %{
      now: Enum.sort_by(grouped[:now] || [], & &1.start_time, DateTime),
      today: Enum.sort_by(grouped[:today] || [], & &1.start_time, DateTime),
      upcoming: Enum.sort_by(grouped[:upcoming] || [], & &1.start_time, DateTime),
      earlier: Enum.sort_by(grouped[:earlier] || [], & &1.start_time, {:desc, DateTime})
    }
  end

  # Terminal meetings (cancelled/missed/archived) are always quieted into Earlier,
  # regardless of when they sit — so Now/Today/Upcoming hold only live, actionable work.
  defp bucket_of(v, now, today) do
    cond do
      terminal?(v.status) -> :earlier
      in_progress?(v, now) -> :now
      ended?(v, now) -> :earlier
      same_day?(v.start_time, today) -> :today
      future_day?(v.start_time, today) -> :upcoming
      true -> :earlier
    end
  end

  defp in_progress?(v, now),
    do: v.status == :IN_PROGRESS or (started?(v, now) and not ended?(v, now))

  defp started?(%{start_time: %DateTime{} = s}, now), do: DateTime.compare(now, s) != :lt
  defp started?(_, _), do: false

  defp ended?(%{end_time: %DateTime{} = e}, now), do: DateTime.compare(now, e) == :gt
  defp ended?(_, _), do: false

  defp same_day?(%DateTime{} = dt, today), do: DateTime.to_date(Florina.Tz.local(dt)) == today
  defp same_day?(_, _), do: false

  defp future_day?(%DateTime{} = dt, today),
    do: Date.compare(DateTime.to_date(Florina.Tz.local(dt)), today) == :gt

  defp future_day?(_, _), do: false

  defp attention_items(visits, sys_default) do
    visits
    |> Enum.filter(&actionable?/1)
    |> Enum.flat_map(&issues_for(&1, sys_default))
    |> Enum.sort_by(&(&1.severity == :error), :desc)
  end

  defp actionable?(v), do: v.calls_enabled and v.status not in [:CANCELLED, :MISSED, :ARCHIVED]

  defp issues_for(v, sys_default) do
    []
    |> add_issue(no_phone?(v), :error, "#{agent_label(v.agent)} has no phone — can't be called")
    |> add_issue(no_methodology?(v, sys_default), :warning, "No methodology set")
    |> add_issue(failed_call?(v), :error, "A call failed — needs a retry")
    |> Enum.map(fn {severity, msg} ->
      %{severity: severity, message: "#{v.title} — #{msg}", visit_id: v.id}
    end)
  end

  defp add_issue(acc, true, severity, msg), do: [{severity, msg} | acc]
  defp add_issue(acc, false, _severity, _msg), do: acc

  defp no_phone?(%{agent: %{phone_number: p}}), do: p in [nil, ""]
  defp no_phone?(_), do: false

  defp no_methodology?(%{methodology_id: nil, agent: %{default_methodology_id: nil}}, nil),
    do: true

  defp no_methodology?(_, _), do: false

  defp failed_call?(%{call_attempts: attempts}) when is_list(attempts),
    do: Enum.any?(attempts, &(&1.status in ["FAILED", "NO_ANSWER"]))

  defp failed_call?(_), do: false

  # ---------------------------------------------------------------------------
  # Per-phase status (derived from call attempts + meeting time)
  # ---------------------------------------------------------------------------

  defp pre_status(v), do: phase_status(v.call_attempts, "PRE")
  defp post_status(v), do: phase_status(v.call_attempts, "POST")

  defp phase_status(attempts, phase) when is_list(attempts) do
    atts = Enum.filter(attempts, &(&1.phase == phase))

    cond do
      atts == [] -> :none
      Enum.any?(atts, &(&1.status == "COMPLETED")) -> :done
      Enum.any?(atts, &(&1.status in ["INITIATED", "IN_PROGRESS"])) -> :live
      Enum.any?(atts, &(&1.status in ["FAILED", "NO_ANSWER"])) -> :failed
      Enum.any?(atts, &(&1.status == "SCHEDULED")) -> :scheduled
      true -> :none
    end
  end

  defp phase_status(_, _), do: :none

  defp meeting_status(v, now) do
    cond do
      ended?(v, now) -> :done
      in_progress?(v, now) -> :live
      true -> :upcoming
    end
  end

  # ---------------------------------------------------------------------------
  # Presentation helpers — status reads in grayscale (icon + word) before color
  # ---------------------------------------------------------------------------

  defp node_icon(:done), do: "hero-check"
  defp node_icon(:failed), do: "hero-x-mark"
  defp node_icon(:live), do: "hero-arrow-path"
  defp node_icon(:scheduled), do: "hero-clock"
  defp node_icon(:upcoming), do: "hero-clock"
  defp node_icon(_none), do: "hero-minus"

  defp node_bg(:done), do: "bg-green-100 dark:bg-green-500/15"
  defp node_bg(:failed), do: "bg-red-100 dark:bg-red-500/15"

  defp node_bg(:live),
    do: "bg-indigo-100 ring-2 ring-indigo-300 dark:bg-indigo-500/20 dark:ring-indigo-500/40"

  defp node_bg(:scheduled), do: "bg-gray-100 dark:bg-white/10"
  defp node_bg(:upcoming), do: "bg-gray-100 dark:bg-white/10"
  defp node_bg(_none), do: "bg-gray-50 dark:bg-white/5"

  defp node_fg(:done), do: "text-green-600 dark:text-green-400"
  defp node_fg(:failed), do: "text-red-600 dark:text-red-400"
  defp node_fg(:live), do: "text-indigo-600 dark:text-indigo-400"
  defp node_fg(:scheduled), do: "text-gray-500 dark:text-gray-400"
  defp node_fg(:upcoming), do: "text-gray-400 dark:text-gray-500"
  defp node_fg(_none), do: "text-gray-300 dark:text-gray-600"

  defp node_label_class(:live), do: "text-indigo-600 dark:text-indigo-400"
  defp node_label_class(:done), do: "text-gray-500 dark:text-gray-400"
  defp node_label_class(:failed), do: "text-red-600 dark:text-red-400"
  defp node_label_class(_), do: "text-gray-400 dark:text-gray-500"

  defp row_class(:now), do: "hover:bg-indigo-50/60 dark:hover:bg-indigo-500/10"

  defp row_class(:earlier),
    do: "opacity-60 hover:opacity-100 hover:bg-gray-50 dark:hover:bg-white/5"

  defp row_class(_), do: "hover:bg-gray-50 dark:hover:bg-white/5"

  defp title_class(:earlier), do: "text-gray-500 dark:text-gray-400"
  defp title_class(_), do: "text-gray-900 dark:text-white"

  defp time_class(:now), do: "font-semibold text-indigo-700 dark:text-indigo-300"
  defp time_class(:earlier), do: "text-gray-400 dark:text-gray-500"
  defp time_class(_), do: "text-gray-700 dark:text-gray-300"

  defp provider_icon(:google), do: "hero-calendar-days"
  defp provider_icon(:microsoft), do: "hero-calendar-days"
  defp provider_icon(_manual), do: "hero-pencil-square"

  defp provider_label(:google), do: "Google"
  defp provider_label(:microsoft), do: "Microsoft"
  defp provider_label(_manual), do: "Manual"

  defp methodology_label(%{methodology: %{name: n}}) when is_binary(n) and n != "", do: n
  defp methodology_label(_), do: nil

  defp last_summary(%{call_attempts: attempts}) when is_list(attempts) do
    attempts
    |> Enum.filter(&(&1.summary not in [nil, ""]))
    |> Enum.sort_by(& &1.id, :desc)
    |> List.first()
    |> case do
      nil -> nil
      c -> truncate(c.summary, 90)
    end
  end

  defp last_summary(_), do: nil

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  # ---------------------------------------------------------------------------
  # Time + label formatting
  # ---------------------------------------------------------------------------

  # Exact clock time; prefixed with the weekday when it isn't today.
  defp clock(now, %DateTime{} = dt) do
    local = Florina.Tz.local(dt)

    if DateTime.to_date(local) == DateTime.to_date(Florina.Tz.local(now)),
      do: Calendar.strftime(local, "%H:%M"),
      else: Calendar.strftime(local, "%a %H:%M")
  end

  defp clock(_now, _), do: "—"

  defp time_phrase(now, %{start_time: %DateTime{} = s} = v, :now) do
    if started?(v, now), do: "started #{words(DateTime.diff(now, s))} ago", else: "starting now"
  end

  defp time_phrase(now, %{start_time: %DateTime{} = s}, :earlier),
    do: "#{words(DateTime.diff(now, s))} ago"

  defp time_phrase(now, %{start_time: %DateTime{} = s}, _),
    do: "in #{words(DateTime.diff(s, now))}"

  defp time_phrase(_now, _v, _kind), do: ""

  defp words(secs) when secs < 60, do: "<1m"
  defp words(secs) when secs < 3600, do: "#{div(secs, 60)}m"
  defp words(secs) when secs < 86_400, do: "#{div(secs, 3600)}h"
  defp words(secs), do: "#{div(secs, 86_400)}d"

  defp empty_title("today"), do: "No meetings today"
  defp empty_title("all"), do: "No meetings yet"
  defp empty_title(_week), do: "No meetings this week"

  # ---------------------------------------------------------------------------
  # Status chip + entity labels
  # ---------------------------------------------------------------------------

  defp status_options do
    Florina.Enums.visit_status_values()
    |> Enum.map(fn
      {k, v} -> {status_label(k), v}
      a when is_atom(a) -> {status_label(a), to_string(a)}
    end)
  end

  defp status_label(status), do: visit_status_label(status)
  # Delegates to the shared tone — this copy previously lacked the COMPLETE (green)
  # and IN_PROGRESS (blue) cases, so those chips rendered grey only on this screen.
  defp status_tone(status), do: visit_status_tone(status)

  defp terminal?(s), do: s in [:CANCELLED, :MISSED, :ARCHIVED]

  defp agent_label(%{first_name: f, last_name: l, email: e}), do: name_of(f, l, e)
  defp agent_label(_), do: "—"
  defp client_label(%{name: n}) when is_binary(n), do: n
  defp client_label(_), do: "—"

  defp name_of(f, l, e) do
    case [f, l] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> e || "—"
      n -> n
    end
  end

  defp filter_select,
    do:
      "rounded-md bg-white py-1.5 pl-3 pr-8 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500"
end
