defmodule FlorinaWeb.CalendarLive do
  @moduledoc """
  Calendar with Day / Week / Month views.

  Managers see **client meetings only** (Visits) across the team — each meeting
  carries the agent's avatar (initials) and two status dots (pre-call / post-call),
  and clicks through to the meeting cockpit; a per-agent filter narrows the view.
  Agents see their **full personal calendar** (every synced event).

  Views:
    * **Day** — a mini-month picker + a meeting list (handles many same-time meetings).
    * **Week** — a Mon–Fri time grid (no weekend meetings by design); events
      placed on a 5-minute row grid.
    * **Month** — a day-cell grid with up to 3 meeting chips per day, then "+N more".

  Crowded days overflow into the Day view, which is a list and never runs out of room.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}

  alias Florina.{Accounts, Authz, CalendarEvents, Visits}

  # Deterministic avatar colors, indexed by agent id (literal classes so Tailwind compiles them).
  @palettes [
    "bg-red-100 text-red-700 dark:bg-red-400/20 dark:text-red-300",
    "bg-orange-100 text-orange-700 dark:bg-orange-400/20 dark:text-orange-300",
    "bg-amber-100 text-amber-700 dark:bg-amber-400/20 dark:text-amber-300",
    "bg-green-100 text-green-700 dark:bg-green-400/20 dark:text-green-300",
    "bg-teal-100 text-teal-700 dark:bg-teal-400/20 dark:text-teal-300",
    "bg-blue-100 text-blue-700 dark:bg-blue-400/20 dark:text-blue-300",
    "bg-indigo-100 text-indigo-700 dark:bg-indigo-400/20 dark:text-indigo-300",
    "bg-purple-100 text-purple-700 dark:bg-purple-400/20 dark:text-purple-300"
  ]

  @impl true
  def mount(_params, _session, socket) do
    agent = socket.assigns.current_agent
    manager? = Authz.manager?(agent)

    {:ok,
     socket
     |> assign(:manager?, manager?)
     |> assign(:scope, Authz.scope(agent))
     |> assign(:agents, (manager? && Accounts.list_agents()) || [])
     |> assign(:filter_agent_id, nil)
     |> assign(:view, :week)
     |> assign(:cursor, Florina.Tz.today())
     |> load()}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("filter", %{"agent_id" => id}, socket),
    do: {:noreply, assign(socket, :filter_agent_id, parse_id(id))}

  def handle_event("set_view", %{"view" => v}, socket)
      when v in ["day", "week", "month"],
      do: {:noreply, socket |> assign(:view, String.to_existing_atom(v)) |> load()}

  def handle_event("today", _params, socket),
    do: {:noreply, socket |> assign(:cursor, Florina.Tz.today()) |> load()}

  def handle_event("prev", _params, socket),
    do:
      {:noreply,
       socket |> assign(:cursor, shift(socket.assigns.view, socket.assigns.cursor, -1)) |> load()}

  def handle_event("next", _params, socket),
    do:
      {:noreply,
       socket |> assign(:cursor, shift(socket.assigns.view, socket.assigns.cursor, 1)) |> load()}

  def handle_event("prev_month", _params, socket),
    do: {:noreply, socket |> assign(:cursor, add_months(socket.assigns.cursor, -1)) |> load()}

  def handle_event("next_month", _params, socket),
    do: {:noreply, socket |> assign(:cursor, add_months(socket.assigns.cursor, 1)) |> load()}

  def handle_event("pick_day", %{"date" => iso}, socket) do
    case Date.from_iso8601(iso) do
      {:ok, date} ->
        {:noreply, socket |> assign(:cursor, date) |> assign(:view, :day) |> load()}

      _ ->
        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load(socket) do
    {from_dt, to_dt} = range_for(socket.assigns.view, socket.assigns.cursor)

    items =
      if socket.assigns.manager? do
        from_dt |> Visits.list_in_range(to_dt) |> Enum.map(&visit_item/1)
      else
        from_dt
        |> CalendarEvents.list_events_between(to_dt, socket.assigns.scope)
        |> Enum.reject(&all_day_event?/1)
        |> Enum.map(&event_item/1)
      end

    assign(socket, :items, items)
  end

  defp range_for(:day, cursor), do: Florina.Tz.day_bounds(cursor)

  defp range_for(:week, cursor) do
    monday = week_monday(cursor)
    {start, _} = Florina.Tz.day_bounds(monday)
    {_, finish} = Florina.Tz.day_bounds(Date.add(monday, 6))
    {start, finish}
  end

  defp range_for(:month, cursor) do
    days = month_grid_days(cursor)
    {start, _} = Florina.Tz.day_bounds(hd(days))
    {_, finish} = Florina.Tz.day_bounds(List.last(days))
    {start, finish}
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
      active={:calendar}
    >
      <% items = Enum.filter(@items, &(is_nil(@filter_agent_id) or &1.agent_id == @filter_agent_id)) %>

      <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
        <div>
          <h1 class="text-2xl font-extrabold tracking-[-0.01em] text-gray-900 sm:text-3xl dark:text-white">
            {title(@view, @cursor)}
          </h1>
          <p class="text-sm text-gray-500 dark:text-gray-400">
            {if @manager?, do: "Client meetings across the team.", else: "Your schedule."}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <form :if={@manager?} phx-change="filter">
            <select
              name="agent_id"
              class="rounded-md bg-white py-1.5 pl-3 pr-8 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500"
            >
              <option value="">All agents</option>
              <option :for={a <- @agents} value={a.id} selected={@filter_agent_id == a.id}>
                {agent_label(a)}
              </option>
            </select>
          </form>

          <%!-- View switcher --%>
          <div class="inline-flex">
            <button
              phx-click="set_view"
              phx-value-view="day"
              class={[seg(@view == :day), "rounded-l-md"]}
            >
              Day
            </button>
            <button phx-click="set_view" phx-value-view="week" class={[seg(@view == :week), "-ml-px"]}>
              Week
            </button>
            <button
              phx-click="set_view"
              phx-value-view="month"
              class={[seg(@view == :month), "-ml-px rounded-r-md"]}
            >
              Month
            </button>
          </div>

          <button phx-click="prev" class={nav_btn()} aria-label="Previous">←</button>
          <button phx-click="today" class={nav_btn()}>Today</button>
          <button phx-click="next" class={nav_btn()} aria-label="Next">→</button>
        </div>
      </div>

      {render_view(assign(assigns, :items, items))}
    </Layouts.agent_app>
    """
  end

  defp render_view(%{view: :month} = assigns), do: month_view(assigns)
  defp render_view(%{view: :day} = assigns), do: day_view(assigns)
  defp render_view(assigns), do: week_view(assigns)

  # ---- Month ----------------------------------------------------------------

  defp month_view(assigns) do
    days = Enum.filter(month_grid_days(assigns.cursor), &(Date.day_of_week(&1) <= 5))
    assigns = assign(assigns, :month_days, days)

    ~H"""
    <div class="rounded-lg border border-gray-200 shadow-sm overflow-hidden dark:border-white/10">
      <div class="grid grid-cols-5 gap-px border-b border-gray-200 bg-white text-center text-xs font-semibold text-gray-700 dark:border-white/10 dark:bg-gray-900 dark:text-gray-300">
        <div :for={d <- ~w(Mon Tue Wed Thu Fri)} class="py-2">{d}</div>
      </div>
      <div class="grid grid-cols-5 grid-rows-6 gap-px bg-gray-200 text-sm dark:bg-white/10">
        <div
          :for={day <- @month_days}
          class={[
            "relative min-h-28 px-2 py-1.5",
            (in_month?(day, @cursor) && "bg-white dark:bg-gray-900") ||
              "bg-gray-50 text-gray-400 dark:bg-gray-900/60"
          ]}
        >
          <% day_items = items_on(@items, day) %>
          <button
            phx-click="pick_day"
            phx-value-date={Date.to_iso8601(day)}
            class={[
              "text-xs cursor-pointer",
              (today?(day) &&
                 "flex size-6 items-center justify-center rounded-full bg-indigo-600 font-semibold text-white dark:bg-indigo-500") ||
                "text-gray-700 dark:text-gray-300"
            ]}
          >
            {day.day}
          </button>
          <ol class="mt-1 space-y-1">
            <li :for={item <- Enum.take(day_items, 3)}>
              <.event_link item={item} slug={@tenant.slug} class="group flex items-center gap-1">
                <.avatar agent={item.agent} class="size-4 text-[0.5rem]" />
                <span class="flex-auto truncate text-xs text-gray-900 group-hover:text-indigo-600 dark:text-white dark:group-hover:text-indigo-400">
                  {item.title}
                </span>
                <.dots :if={@manager?} pre={item.pre} post={item.post} />
              </.event_link>
            </li>
            <li :if={length(day_items) > 3}>
              <button
                phx-click="pick_day"
                phx-value-date={Date.to_iso8601(day)}
                class="text-xs font-medium text-gray-500 hover:text-indigo-600 dark:text-gray-400 dark:hover:text-indigo-400"
              >
                + {length(day_items) - 3} more
              </button>
            </li>
          </ol>
        </div>
      </div>
    </div>
    """
  end

  # ---- Day (mini-month picker + meeting list) -------------------------------

  defp day_view(assigns) do
    ~H"""
    <div class="lg:grid lg:grid-cols-12 lg:gap-8">
      <div class="lg:col-span-4 xl:col-span-3">
        <.mini_month cursor={@cursor} />
      </div>

      <ol class="mt-6 lg:mt-0 lg:col-span-8 xl:col-span-9 divide-y divide-gray-200 rounded-lg border border-gray-200 dark:divide-white/10 dark:border-white/10">
        <li
          :for={item <- items_on(@items, @cursor)}
          class="flex items-center gap-4 px-4 py-3 hover:bg-gray-50 dark:hover:bg-white/5"
        >
          <.avatar agent={item.agent} class="size-9 text-xs" />
          <div class="min-w-0 flex-auto">
            <p class="truncate font-semibold text-gray-900 dark:text-white">{item.title}</p>
            <p class="truncate text-sm text-gray-500 dark:text-gray-400">
              {time_range(item)}{secondary(item)}
            </p>
          </div>
          <.dots :if={@manager?} pre={item.pre} post={item.post} />
          <.link
            :if={item.visit_id}
            navigate={"/t/#{@tenant.slug}/manage/meetings/#{item.visit_id}"}
            class="shrink-0 text-sm font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
          >
            Open
          </.link>
        </li>
        <li
          :if={items_on(@items, @cursor) == []}
          class="px-4 py-10 text-center text-sm text-gray-500 dark:text-gray-400"
        >
          Nothing scheduled for {Calendar.strftime(@cursor, "%A, %d %B")}.
        </li>
      </ol>
    </div>
    """
  end

  # ---- Week (time grid) -----------------------------------------------------

  defp week_view(assigns) do
    days = Enum.map(0..4, &Date.add(week_monday(assigns.cursor), &1))
    weekday_items = Enum.filter(assigns.items, &(weekday(&1) <= 5))
    placed = place_week(weekday_items)
    overflow = placed |> Enum.filter(& &1.hidden) |> Enum.frequencies_by(&weekday(&1.item))

    assigns =
      assign(assigns, days: days, placed: Enum.reject(placed, & &1.hidden), overflow: overflow)

    ~H"""
    <div class="flex h-[75vh] flex-col rounded-lg border border-gray-200 overflow-hidden dark:border-white/10">
      <div class="isolate flex flex-auto flex-col overflow-auto bg-white dark:bg-gray-900">
        <div class="flex max-w-full flex-none flex-col">
          <div class="sticky top-0 z-30 flex-none bg-white shadow-sm ring-1 ring-black/5 sm:pr-8 dark:bg-gray-900 dark:ring-white/20">
            <div class="grid grid-cols-5 text-sm/6 text-gray-500 sm:hidden dark:text-gray-400">
              <button
                :for={d <- @days}
                type="button"
                phx-click="pick_day"
                phx-value-date={Date.to_iso8601(d)}
                class="flex flex-col items-center pt-2 pb-3"
              >
                {String.first(Calendar.strftime(d, "%A"))}
                <span class={[
                  "mt-1 flex size-8 items-center justify-center font-semibold",
                  (today?(d) && "rounded-full bg-indigo-600 text-white dark:bg-indigo-500") ||
                    "text-gray-900 dark:text-white"
                ]}>{d.day}</span>
              </button>
            </div>

            <div class="-mr-px hidden grid-cols-5 divide-x divide-gray-100 border-r border-gray-100 text-sm/6 text-gray-500 sm:grid dark:divide-white/10 dark:border-white/10 dark:text-gray-400">
              <div class="col-end-1 w-14"></div>
              <button
                :for={d <- @days}
                type="button"
                phx-click="pick_day"
                phx-value-date={Date.to_iso8601(d)}
                class="flex items-center justify-center py-3 hover:bg-gray-50 dark:hover:bg-white/5"
              >
                <span class="flex items-baseline">
                  {Calendar.strftime(d, "%a")}
                  <span class={[
                    "ml-1.5 flex size-8 items-center justify-center font-semibold",
                    (today?(d) && "rounded-full bg-indigo-600 text-white dark:bg-indigo-500") ||
                      "text-gray-900 dark:text-white"
                  ]}>{d.day}</span>
                  <span
                    :if={@overflow[Date.day_of_week(d)]}
                    class="ml-1 rounded-full bg-gray-100 px-1.5 text-[0.625rem] font-semibold text-gray-600 dark:bg-white/10 dark:text-gray-300"
                  >
                    +{@overflow[Date.day_of_week(d)]}
                  </span>
                </span>
              </button>
            </div>
          </div>

          <div class="flex flex-auto">
            <div class="sticky left-0 z-10 w-14 flex-none bg-white ring-1 ring-gray-100 dark:bg-gray-900 dark:ring-white/5">
            </div>
            <div class="grid flex-auto grid-cols-1 grid-rows-1">
              <div
                style="grid-template-rows: repeat(24, minmax(3.5rem, 1fr))"
                class="col-start-1 col-end-2 row-start-1 grid divide-y divide-gray-100 dark:divide-white/5"
              >
                <div class="row-end-1 h-7"></div>
                <%= for h <- day_start_hour()..(day_end_hour() - 1) do %>
                  <div>
                    <div class="sticky left-0 z-20 -mt-2.5 -ml-14 w-14 pr-2 text-right text-xs/5 text-gray-400 dark:text-gray-500">
                      {hour_label(h)}
                    </div>
                  </div>
                  <div></div>
                <% end %>
              </div>

              <div class="col-start-1 col-end-2 row-start-1 hidden grid-rows-1 divide-x divide-gray-100 sm:grid sm:grid-cols-5 dark:divide-white/5">
                <div class="col-start-1 row-span-full"></div>
                <div class="col-start-2 row-span-full"></div>
                <div class="col-start-3 row-span-full"></div>
                <div class="col-start-4 row-span-full"></div>
                <div class="col-start-5 row-span-full"></div>
                <div class="col-start-6 row-span-full w-8"></div>
              </div>

              <ol
                style="grid-template-rows: 1.75rem repeat(144, minmax(0, 1fr)) auto"
                class="col-start-1 col-end-2 row-start-1 grid grid-cols-1 sm:grid-cols-5 sm:pr-8"
              >
                <li
                  :for={p <- @placed}
                  style={grid_row(p.item)}
                  class={["relative mt-px flex", col_class(weekday(p.item))]}
                >
                  <% c = ev_color(p.item) %>
                  <.event_link
                    item={p.item}
                    slug={@tenant.slug}
                    style={lane_style(p)}
                    class={[
                      "group absolute inset-y-1 flex flex-col overflow-y-auto rounded-lg p-1.5 text-xs/5",
                      c.box
                    ]}
                  >
                    <div class="order-1 flex items-center gap-1">
                      <.avatar agent={p.item.agent} class="size-4 text-[0.5rem]" />
                      <span class={["truncate font-semibold", c.title]}>{p.item.title}</span>
                      <.dots :if={@manager?} pre={p.item.pre} post={p.item.post} />
                    </div>
                    <p class={c.time}>{fmt(p.item.start_time)}</p>
                  </.event_link>
                </li>
              </ol>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---- Mini-month picker (used in Day view) ---------------------------------

  attr :cursor, Date, required: true

  defp mini_month(assigns) do
    assigns = assign(assigns, :days, month_grid_days(assigns.cursor))

    ~H"""
    <div class="text-center">
      <div class="flex items-center text-gray-900 dark:text-white">
        <button
          phx-click="prev_month"
          class="-m-1.5 flex flex-none items-center justify-center p-1.5 text-gray-400 hover:text-gray-500 dark:hover:text-white"
        >
          ←
        </button>
        <div class="flex-auto text-sm font-semibold">{Calendar.strftime(@cursor, "%B %Y")}</div>
        <button
          phx-click="next_month"
          class="-m-1.5 flex flex-none items-center justify-center p-1.5 text-gray-400 hover:text-gray-500 dark:hover:text-white"
        >
          →
        </button>
      </div>
      <div class="mt-4 grid grid-cols-7 text-xs/6 text-gray-500 dark:text-gray-400">
        <div :for={d <- ~w(M T W T F S S)}>{d}</div>
      </div>
      <div class="isolate mt-2 grid grid-cols-7 gap-px overflow-hidden rounded-lg bg-gray-200 text-sm shadow-sm ring-1 ring-gray-200 dark:bg-white/10 dark:ring-white/10">
        <button
          :for={d <- @days}
          type="button"
          phx-click="pick_day"
          phx-value-date={Date.to_iso8601(d)}
          class={[
            "py-1.5 hover:bg-gray-100 focus:z-10 dark:hover:bg-white/5",
            (in_month?(d, @cursor) && "bg-white dark:bg-gray-900") ||
              "bg-gray-50 dark:bg-gray-900/60"
          ]}
        >
          <time class={[
            "mx-auto flex size-7 items-center justify-center rounded-full",
            d == @cursor && today?(d) && "bg-indigo-600 font-semibold text-white dark:bg-indigo-500",
            d == @cursor && !today?(d) &&
              "bg-gray-900 font-semibold text-white dark:bg-white dark:text-gray-900",
            d != @cursor && today?(d) && "font-semibold text-indigo-600 dark:text-indigo-400",
            d != @cursor && !today?(d) && in_month?(d, @cursor) && "text-gray-900 dark:text-white",
            d != @cursor && !today?(d) && !in_month?(d, @cursor) && "text-gray-400 dark:text-gray-500"
          ]}>
            {d.day}
          </time>
        </button>
      </div>
    </div>
    """
  end

  # ---- Shared bits ----------------------------------------------------------

  attr :item, :map, required: true
  attr :slug, :string, required: true
  attr :class, :any, default: nil
  attr :style, :string, default: nil
  slot :inner_block, required: true

  # Wrap meeting content in a link (manager Visits) or a plain div (agent events).
  defp event_link(assigns) do
    ~H"""
    <.link
      :if={@item.visit_id}
      navigate={"/t/#{@slug}/manage/meetings/#{@item.visit_id}"}
      class={@class}
      style={@style}
    >
      {render_slot(@inner_block)}
    </.link>
    <div :if={is_nil(@item.visit_id)} class={@class} style={@style}>{render_slot(@inner_block)}</div>
    """
  end

  attr :agent, :map, default: nil
  attr :class, :string, default: "size-6 text-[0.625rem]"

  defp avatar(assigns) do
    ~H"""
    <span
      :if={@agent}
      class={[
        "inline-flex shrink-0 items-center justify-center rounded-full font-medium",
        @class,
        palette(@agent.id)
      ]}
      title={agent_label(@agent)}
    >
      {initials(@agent)}
    </span>
    """
  end

  attr :pre, :atom, required: true
  attr :post, :atom, required: true

  defp dots(assigns) do
    ~H"""
    <span class="ml-auto inline-flex shrink-0 items-center gap-0.5">
      <span class={["size-1.5 rounded-full", dot(@pre)]} title={"Pre-call: #{dot_label(@pre)}"} />
      <span class={["size-1.5 rounded-full", dot(@post)]} title={"Post-call: #{dot_label(@post)}"} />
    </span>
    """
  end

  defp dot(:done), do: "bg-green-500"
  defp dot(:failed), do: "bg-red-500"
  defp dot(:pending), do: "bg-amber-400"
  defp dot(_), do: "bg-gray-300 dark:bg-gray-600"

  defp dot_label(:done), do: "done"
  defp dot_label(:failed), do: "failed"
  defp dot_label(:pending), do: "in progress"
  defp dot_label(_), do: "not yet"

  defp palette(id), do: Enum.at(@palettes, rem(abs(id || 0), length(@palettes)))

  defp initials(agent) do
    case agent |> agent_label() |> String.split(~r/\s+/, trim: true) do
      [a, b | _] -> String.upcase(String.first(a) <> String.first(b))
      [a] -> String.upcase(String.slice(a, 0, 2))
      _ -> "?"
    end
  end

  defp seg(true),
    do:
      "px-3 py-1.5 text-sm font-semibold bg-indigo-600 text-white shadow-xs cursor-pointer dark:bg-indigo-500"

  defp seg(false),
    do:
      "px-3 py-1.5 text-sm font-semibold bg-white text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 cursor-pointer dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"

  defp nav_btn,
    do:
      "rounded-md bg-white px-3 py-1.5 text-sm font-semibold text-gray-900 shadow-xs ring-1 ring-inset ring-gray-300 hover:bg-gray-50 cursor-pointer dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"

  # ---- Item builders --------------------------------------------------------

  defp visit_item(v) do
    %{
      start_time: v.start_time,
      end_time: v.end_time,
      title: v.title,
      agent: v.agent,
      agent_id: v.agent_id,
      client_name: client_label(v.client),
      status: v.status,
      visit_id: v.id,
      pre: call_status(v.call_attempts, "PRE"),
      post: call_status(v.call_attempts, "POST")
    }
  end

  defp event_item(ev) do
    %{
      start_time: ev.start_time,
      end_time: ev.end_time,
      title: ev.title,
      agent: nil,
      agent_id: ev.user_id,
      client_name: nil,
      status: nil,
      visit_id: nil,
      pre: :none,
      post: :none
    }
  end

  defp call_status(attempts, phase) when is_list(attempts) do
    atts = Enum.filter(attempts, &(&1.phase == phase))

    cond do
      atts == [] -> :none
      Enum.any?(atts, &(&1.status == "COMPLETED")) -> :done
      Enum.any?(atts, &(&1.status in ["FAILED", "NO_ANSWER"])) -> :failed
      true -> :pending
    end
  end

  defp call_status(_, _), do: :none

  # Legacy all-day rows (Microsoft isAllDay; Google all-day events have date, not dateTime).
  defp all_day_event?(%{raw: raw}) when is_map(raw) do
    raw["isAllDay"] == true or
      (is_map(raw["start"]) and is_nil(raw["start"]["dateTime"]) and
         not is_nil(raw["start"]["date"]))
  end

  defp all_day_event?(_), do: false

  # ---- Date / time helpers --------------------------------------------------

  defp items_on(items, date) do
    items
    |> Enum.filter(fn i -> DateTime.to_date(Florina.Tz.local(i.start_time)) == date end)
    |> Enum.sort_by(& &1.start_time, DateTime)
  end

  defp today?(day), do: day == Florina.Tz.today()

  defp in_month?(day, cursor), do: day.month == cursor.month and day.year == cursor.year

  defp week_monday(date), do: Date.add(date, -(Date.day_of_week(date) - 1))

  defp month_grid_days(cursor) do
    start = cursor |> Date.beginning_of_month() |> week_monday()
    Enum.map(0..41, &Date.add(start, &1))
  end

  defp shift(:day, cursor, n), do: Date.add(cursor, n)
  defp shift(:week, cursor, n), do: Date.add(cursor, n * 7)
  defp shift(:month, cursor, n), do: add_months(cursor, n)

  defp add_months(date, n) do
    m0 = date.year * 12 + (date.month - 1) + n
    y = div(m0, 12)
    m = rem(m0, 12) + 1
    last = Date.days_in_month(Date.new!(y, m, 1))
    Date.new!(y, m, min(date.day, last))
  end

  defp title(:day, cursor), do: Calendar.strftime(cursor, "%A, %d %B %Y")
  defp title(:week, cursor), do: week_range_label(week_monday(cursor))
  defp title(:month, cursor), do: Calendar.strftime(cursor, "%B %Y")

  defp week_range_label(monday),
    do:
      "#{Calendar.strftime(monday, "%d %b")} – #{Calendar.strftime(Date.add(monday, 6), "%d %b %Y")}"

  defp time_range(%{start_time: s, end_time: %DateTime{} = e}), do: "#{fmt(s)} – #{fmt(e)}"
  defp time_range(%{start_time: s}), do: fmt(s)

  defp secondary(%{client_name: c, agent: a}) when is_binary(c) and not is_nil(a),
    do: " · #{c} · #{agent_label(a)}"

  defp secondary(_), do: ""

  defp fmt(%DateTime{} = dt), do: Florina.Tz.format(dt, :time)

  # ---- Week-grid placement --------------------------------------------------

  defp weekday(item),
    do: item.start_time |> Florina.Tz.local() |> DateTime.to_date() |> Date.day_of_week()

  # Side-by-side placement: per weekday, group overlapping meetings into clusters,
  # assign each a lane, and mark lanes ≥ 3 hidden (surfaced as a "+N" on the header).
  defp place_week(items) do
    items
    |> Enum.group_by(&weekday/1)
    |> Enum.flat_map(fn {_wd, day_items} -> lanes_for_day(day_items) end)
  end

  defp lanes_for_day(items) do
    items
    |> Enum.sort_by(& &1.start_time, DateTime)
    |> cluster([])
    |> Enum.flat_map(&assign_lanes/1)
  end

  defp cluster([], acc), do: Enum.reverse(acc)

  defp cluster([ev | rest], acc) do
    {group, remaining} = take_overlapping(rest, [ev], ev_end(ev))
    cluster(remaining, [group | acc])
  end

  defp take_overlapping([ev | rest], group, group_end) do
    if DateTime.compare(ev.start_time, group_end) == :lt do
      take_overlapping(rest, [ev | group], max_dt(group_end, ev_end(ev)))
    else
      {Enum.reverse(group), [ev | rest]}
    end
  end

  defp take_overlapping([], group, _group_end), do: {Enum.reverse(group), []}

  defp assign_lanes(group) do
    {placed, lanes} =
      Enum.reduce(group, {[], %{}}, fn ev, {placed, lanes} ->
        idx = free_lane(lanes, ev.start_time)
        {[{ev, idx} | placed], Map.put(lanes, idx, ev_end(ev))}
      end)

    denom = map_size(lanes)

    for {ev, idx} <- Enum.reverse(placed),
        do: %{item: ev, lane: idx, denom: denom, hidden: idx >= 3}
  end

  defp free_lane(lanes, start) do
    free =
      for {i, e} <- lanes, DateTime.compare(e, start) != :gt, do: i

    case free do
      [] -> map_size(lanes)
      list -> Enum.min(list)
    end
  end

  defp ev_end(%{end_time: %DateTime{} = e}), do: e
  defp ev_end(%{start_time: s}), do: DateTime.add(s, 30 * 60, :second)

  defp max_dt(a, b), do: (DateTime.compare(a, b) == :lt && b) || a

  # Horizontal lane position within the day column (capped at 3 visible lanes).
  defp lane_style(%{lane: lane, denom: denom}) do
    vdenom = min(denom, 3)
    left = lane * 100 / vdenom
    width = 100 / vdenom
    "left: #{left}%; width: calc(#{width}% - 4px)"
  end

  # Visible window for the week time grid (no point rendering 3 AM / 11 PM).
  defp day_start_hour, do: 8
  defp day_end_hour, do: 20

  defp grid_row(item) do
    start_min = minutes_into_window(item.start_time)
    row = 2 + div(start_min, 5)
    "grid-row: #{row} / span #{span_rows(item, start_min)}"
  end

  # Minutes from the window start (8 AM), clamped into the 8 AM–8 PM window.
  defp minutes_into_window(dt) do
    s = Florina.Tz.local(dt)
    clamp(s.hour * 60 + s.minute - day_start_hour() * 60, 0, window_minutes())
  end

  defp window_minutes, do: (day_end_hour() - day_start_hour()) * 60

  defp span_rows(item, start_min) do
    end_min =
      case item.end_time do
        %DateTime{} = e -> minutes_into_window(e)
        _ -> start_min + 30
      end

    # at least 30 min tall, never past the bottom of the window
    span = max(div(end_min - start_min, 5), 6)
    remaining = max(div(window_minutes(), 5) - div(start_min, 5), 1)
    min(span, remaining)
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp col_class(1), do: "sm:col-start-1"
  defp col_class(2), do: "sm:col-start-2"
  defp col_class(3), do: "sm:col-start-3"
  defp col_class(4), do: "sm:col-start-4"
  defp col_class(5), do: "sm:col-start-5"
  defp col_class(6), do: "sm:col-start-6"
  defp col_class(7), do: "sm:col-start-7"

  defp hour_label(0), do: "12AM"
  defp hour_label(12), do: "12PM"
  defp hour_label(h) when h < 12, do: "#{h}AM"
  defp hour_label(h), do: "#{h - 12}PM"

  defp ev_color(%{status: :COMPLETE}), do: ev_palette(:green)
  defp ev_color(%{status: :IN_PROGRESS}), do: ev_palette(:indigo)
  defp ev_color(%{status: s}) when s in [:MISSED, :CANCELLED, :ARCHIVED], do: ev_palette(:gray)
  defp ev_color(_), do: ev_palette(:blue)

  defp ev_palette(:blue),
    do: %{
      box: "bg-blue-50 hover:bg-blue-100 dark:bg-blue-600/15 dark:hover:bg-blue-600/20",
      title: "text-blue-700 dark:text-blue-300",
      time:
        "text-blue-500 group-hover:text-blue-700 dark:text-blue-400 dark:group-hover:text-blue-300"
    }

  defp ev_palette(:green),
    do: %{
      box: "bg-green-50 hover:bg-green-100 dark:bg-green-600/15 dark:hover:bg-green-600/20",
      title: "text-green-700 dark:text-green-300",
      time:
        "text-green-500 group-hover:text-green-700 dark:text-green-400 dark:group-hover:text-green-300"
    }

  defp ev_palette(:indigo),
    do: %{
      box: "bg-indigo-50 hover:bg-indigo-100 dark:bg-indigo-600/15 dark:hover:bg-indigo-600/20",
      title: "text-indigo-700 dark:text-indigo-300",
      time:
        "text-indigo-500 group-hover:text-indigo-700 dark:text-indigo-400 dark:group-hover:text-indigo-300"
    }

  defp ev_palette(:gray),
    do: %{
      box: "bg-gray-100 hover:bg-gray-200 dark:bg-white/10 dark:hover:bg-white/15",
      title: "text-gray-700 dark:text-gray-300",
      time:
        "text-gray-500 group-hover:text-gray-700 dark:text-gray-400 dark:group-hover:text-gray-300"
    }

  defp agent_label(nil), do: "—"

  defp agent_label(user) do
    name = [user.first_name, user.last_name] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
    if name == "", do: user.email || user.username, else: name
  end

  defp client_label(%{name: n}) when is_binary(n), do: n
  defp client_label(_), do: "—"

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_id(_), do: nil
end
