defmodule FlorinaWeb.CalendarLive do
  @moduledoc """
  Week-view calendar grid (Mon–Sun columns, time-of-day rows) — events are
  positioned on a 5-minute time grid by their start/end time.

  Managers see **client meetings only** (Visits) across the team — the things
  Florina acts on — each clickable through to the meeting cockpit, with a
  per-agent filter. Agents see their **full personal calendar** (every synced
  event), since the whole schedule is useful context for them.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}

  alias Florina.{Accounts, Authz, CalendarEvents, Visits}

  @impl true
  def mount(_params, _session, socket) do
    monday = week_monday(Florina.Tz.today())
    agent = socket.assigns.current_agent
    manager? = Authz.manager?(agent)

    {:ok,
     socket
     |> assign(:manager?, manager?)
     |> assign(:scope, Authz.scope(agent))
     |> assign(:agents, (manager? && Accounts.list_agents()) || [])
     |> assign(:filter_agent_id, nil)
     |> load_week(monday)}
  end

  @impl true
  def handle_event("filter", %{"agent_id" => id}, socket),
    do: {:noreply, assign(socket, :filter_agent_id, parse_id(id))}

  def handle_event("prev_week", _params, socket),
    do: {:noreply, load_week(socket, Date.add(socket.assigns.monday, -7))}

  def handle_event("next_week", _params, socket),
    do: {:noreply, load_week(socket, Date.add(socket.assigns.monday, 7))}

  def handle_event("this_week", _params, socket),
    do: {:noreply, load_week(socket, week_monday(Florina.Tz.today()))}

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
      <div class="flex flex-wrap items-center justify-between gap-3 mb-1">
        <div>
          <h1 class="text-2xl font-semibold text-gray-900 dark:text-white">Calendar</h1>
          <p class="text-sm text-gray-500 dark:text-gray-400">
            {if @manager?, do: "Client meetings across the team.", else: "Your schedule."}
          </p>
        </div>
        <div class="flex items-center gap-2">
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
          <button phx-click="prev_week" class={nav_btn()} aria-label="Previous week">←</button>
          <button phx-click="this_week" class={nav_btn()}>{week_range_label(@monday)}</button>
          <button phx-click="next_week" class={nav_btn()} aria-label="Next week">→</button>
        </div>
      </div>

      <%!-- Week grid (adapted from Tailwind Plus "Week view"). Events are placed on a
           288-row time grid via inline grid-row; columns 1–7 are Mon–Sun. --%>
      <div class="mt-4 flex h-[75vh] flex-col rounded-lg border border-gray-200 overflow-hidden dark:border-white/10">
        <div class="isolate flex flex-auto flex-col overflow-auto bg-white dark:bg-gray-900">
          <div class="flex max-w-full flex-none flex-col">
            <%!-- Day headers --%>
            <div class="sticky top-0 z-30 flex-none bg-white shadow-sm ring-1 ring-black/5 sm:pr-8 dark:bg-gray-900 dark:ring-white/20">
              <div class="grid grid-cols-7 text-sm/6 text-gray-500 sm:hidden dark:text-gray-400">
                <span :for={d <- @days} class="flex flex-col items-center pt-2 pb-3">
                  {String.first(Calendar.strftime(d, "%A"))}
                  <span class={[
                    "mt-1 flex size-8 items-center justify-center font-semibold",
                    (today?(d) && "rounded-full bg-indigo-600 text-white dark:bg-indigo-500") ||
                      "text-gray-900 dark:text-white"
                  ]}>{d.day}</span>
                </span>
              </div>

              <div class="-mr-px hidden grid-cols-7 divide-x divide-gray-100 border-r border-gray-100 text-sm/6 text-gray-500 sm:grid dark:divide-white/10 dark:border-white/10 dark:text-gray-400">
                <div class="col-end-1 w-14"></div>
                <div :for={d <- @days} class="flex items-center justify-center py-3">
                  <span class="flex items-baseline">
                    {Calendar.strftime(d, "%a")}
                    <span class={[
                      "ml-1.5 flex size-8 items-center justify-center font-semibold",
                      (today?(d) && "rounded-full bg-indigo-600 text-white dark:bg-indigo-500") ||
                        "text-gray-900 dark:text-white"
                    ]}>{d.day}</span>
                  </span>
                </div>
              </div>
            </div>

            <div class="flex flex-auto">
              <div class="sticky left-0 z-10 w-14 flex-none bg-white ring-1 ring-gray-100 dark:bg-gray-900 dark:ring-white/5">
              </div>
              <div class="grid flex-auto grid-cols-1 grid-rows-1">
                <%!-- Horizontal hour lines --%>
                <div
                  style="grid-template-rows: repeat(48, minmax(3.5rem, 1fr))"
                  class="col-start-1 col-end-2 row-start-1 grid divide-y divide-gray-100 dark:divide-white/5"
                >
                  <div class="row-end-1 h-7"></div>
                  <%= for h <- 0..23 do %>
                    <div>
                      <div class="sticky left-0 z-20 -mt-2.5 -ml-14 w-14 pr-2 text-right text-xs/5 text-gray-400 dark:text-gray-500">
                        {hour_label(h)}
                      </div>
                    </div>
                    <div></div>
                  <% end %>
                </div>

                <%!-- Vertical day lines --%>
                <div class="col-start-1 col-end-2 row-start-1 hidden grid-rows-1 divide-x divide-gray-100 sm:grid sm:grid-cols-7 dark:divide-white/5">
                  <div class="col-start-1 row-span-full"></div>
                  <div class="col-start-2 row-span-full"></div>
                  <div class="col-start-3 row-span-full"></div>
                  <div class="col-start-4 row-span-full"></div>
                  <div class="col-start-5 row-span-full"></div>
                  <div class="col-start-6 row-span-full"></div>
                  <div class="col-start-7 row-span-full"></div>
                  <div class="col-start-8 row-span-full w-8"></div>
                </div>

                <%!-- Events --%>
                <ol
                  style="grid-template-rows: 1.75rem repeat(288, minmax(0, 1fr)) auto"
                  class="col-start-1 col-end-2 row-start-1 grid grid-cols-1 sm:grid-cols-7 sm:pr-8"
                >
                  <li
                    :for={item <- items}
                    style={grid_row(item)}
                    class={["relative mt-px flex", col_class(weekday(item))]}
                  >
                    <% c = ev_color(item) %>
                    <.link
                      :if={item.visit_id}
                      navigate={"/t/#{@tenant.slug}/manage/meetings/#{item.visit_id}"}
                      class={[
                        "group absolute inset-1 flex flex-col overflow-y-auto rounded-lg p-2 text-xs/5",
                        c.box
                      ]}
                    >
                      <p class={["order-1 font-semibold", c.title]}>{item.title}</p>
                      <p class={c.time}>{fmt(item.start_time)}</p>
                    </.link>
                    <div
                      :if={is_nil(item.visit_id)}
                      class={[
                        "absolute inset-1 flex flex-col overflow-y-auto rounded-lg p-2 text-xs/5",
                        c.box
                      ]}
                    >
                      <p class={["order-1 font-semibold", c.title]}>{item.title}</p>
                      <p class={c.time}>{fmt(item.start_time)}</p>
                    </div>
                  </li>
                </ol>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.agent_app>
    """
  end

  defp load_week(socket, monday) do
    from_dt = DateTime.new!(monday, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(Date.add(monday, 6), ~T[23:59:59], "Etc/UTC")

    items =
      if socket.assigns.manager? do
        from_dt |> Visits.list_in_range(to_dt) |> Enum.map(&visit_item/1)
      else
        from_dt
        |> CalendarEvents.list_events_between(to_dt, socket.assigns.scope)
        |> Enum.reject(&all_day_event?/1)
        |> Enum.map(&event_item/1)
      end

    # Full Mon–Sun week as columns. Past *unhandled* meetings are already retired
    # to :MISSED (excluded by list_in_range), so past days only show real history.
    days = Enum.map(0..6, &Date.add(monday, &1))

    socket
    |> assign(:monday, monday)
    |> assign(:days, days)
    |> assign(:items, items)
  end

  # Manager item: a client meeting (Visit) — linked, with client + agent + status.
  defp visit_item(v) do
    %{
      start_time: v.start_time,
      end_time: v.end_time,
      title: v.title,
      secondary: "#{client_label(v.client)} · #{agent_label(v.agent)}",
      agent_id: v.agent_id,
      status: v.status,
      visit_id: v.id
    }
  end

  # Agent item: a raw calendar event — no link, no status.
  defp event_item(ev) do
    %{
      start_time: ev.start_time,
      end_time: ev.end_time,
      title: ev.title,
      secondary: nil,
      agent_id: ev.user_id,
      status: nil,
      visit_id: nil
    }
  end

  # Legacy all-day rows already stored before the provider-level filter landed.
  # Detect from the original payload kept in `raw` (Microsoft isAllDay; Google
  # all-day events have a "date" but no "dateTime" on start).
  defp all_day_event?(%{raw: raw}) when is_map(raw) do
    raw["isAllDay"] == true or
      (is_map(raw["start"]) and is_nil(raw["start"]["dateTime"]) and
         not is_nil(raw["start"]["date"]))
  end

  defp all_day_event?(_), do: false

  defp today?(day), do: day == Florina.Tz.today()

  # ---- Week-grid placement ----------------------------------------------------

  # Mon=1 … Sun=7, matching the 7 grid columns.
  defp weekday(item),
    do: item.start_time |> Florina.Tz.local() |> DateTime.to_date() |> Date.day_of_week()

  # The events grid has a 1.75rem header row then 288 five-minute rows, so a
  # local time T maps to row 2 + (minutes-since-midnight / 5).
  defp grid_row(item) do
    s = Florina.Tz.local(item.start_time)
    row = 2 + div(s.hour * 60 + s.minute, 5)
    "grid-row: #{row} / span #{span_rows(item)}"
  end

  defp span_rows(%{end_time: %DateTime{} = e, start_time: s}),
    do: max(div(max(DateTime.diff(e, s, :minute), 5), 5), 6)

  defp span_rows(_), do: 6

  # Literal returns so Tailwind's scanner sees each class (dynamic strings aren't compiled).
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
  defp ev_color(%{status: s}) when s in [:MISSED, :CANCELLED], do: ev_palette(:gray)
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

  defp week_monday(date), do: Date.add(date, -(Date.day_of_week(date) - 1))

  defp week_range_label(monday),
    do:
      "#{Calendar.strftime(monday, "%d %b")} – #{Calendar.strftime(Date.add(monday, 6), "%d %b")}"

  defp fmt(%DateTime{} = dt), do: Calendar.strftime(Florina.Tz.local(dt), "%H:%M")

  # Shared TW Plus secondary button styling for the week-nav controls.
  defp nav_btn,
    do:
      "rounded-md bg-white px-3 py-1.5 text-sm font-semibold text-gray-900 shadow-xs ring-1 ring-inset ring-gray-300 hover:bg-gray-50 cursor-pointer dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"

  defp agent_label(nil), do: "—"

  defp agent_label(user) do
    name = [user.first_name, user.last_name] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
    if name == "", do: user.email || user.username, else: name
  end

  defp client_label(%{name: n}) when is_binary(n), do: n
  defp client_label(_), do: "—"

  defp parse_id(""), do: nil
  defp parse_id(id), do: String.to_integer(id)
end
