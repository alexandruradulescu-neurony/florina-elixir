defmodule FlorinaWeb.CalendarLive do
  @moduledoc """
  Week agenda of appointments.

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
      <div class="flex flex-wrap items-center justify-between gap-3 mb-1">
        <h1 class="text-2xl font-semibold">Calendar</h1>
        <div class="flex items-center gap-2">
          <form :if={@manager?} phx-change="filter">
            <select name="agent_id" class="select select-bordered select-sm">
              <option value="">All agents</option>
              <option :for={a <- @agents} value={a.id} selected={@filter_agent_id == a.id}>
                {agent_label(a)}
              </option>
            </select>
          </form>
          <button phx-click="prev_week" class="btn btn-sm" aria-label="Previous week">←</button>
          <button phx-click="this_week" class="btn btn-sm">{week_range_label(@monday)}</button>
          <button phx-click="next_week" class="btn btn-sm" aria-label="Next week">→</button>
        </div>
      </div>
      <p class="text-sm text-base-content/50 mb-6">
        {if @manager?, do: "Client meetings across the team.", else: "Your schedule."}
      </p>

      <div class="space-y-6 max-w-2xl">
        <section :for={day <- days_with_items(@days, @items, @filter_agent_id)}>
          <h2 class={[
            "text-sm font-semibold mb-2",
            (today?(day) && "text-primary") || "text-base-content/60"
          ]}>
            {Calendar.strftime(day, "%A, %d %B")}{if today?(day), do: " · Today"}
          </h2>
          <div class="space-y-2">
            <div
              :for={item <- items_for(@items, day, @filter_agent_id)}
              class="flex items-center gap-3 rounded-lg border border-base-300 px-3 py-2"
            >
              <div class="w-28 shrink-0 text-sm font-medium text-base-content/80">
                {time_range(item)}
              </div>
              <div class="min-w-0">
                <.link
                  :if={item.visit_id}
                  navigate={"/t/#{@tenant.slug}/manage/meetings/#{item.visit_id}"}
                  class="block text-sm font-medium text-primary hover:underline truncate"
                >
                  {item.title}
                </.link>
                <span :if={is_nil(item.visit_id)} class="block text-sm font-medium truncate">
                  {item.title}
                </span>
                <div :if={item.secondary} class="text-xs text-base-content/50">{item.secondary}</div>
              </div>
              <span
                :if={item.status}
                class={[
                  "ml-auto shrink-0 rounded-full px-2 py-0.5 text-xs font-medium",
                  status_tone(item.status)
                ]}
              >
                {status_label(item.status)}
              </span>
            </div>
          </div>
        </section>

        <p
          :if={days_with_items(@days, @items, @filter_agent_id) == []}
          class="text-sm text-base-content/50 rounded-lg border border-dashed border-base-300 px-4 py-8 text-center"
        >
          {if @manager?, do: "No client meetings this week.", else: "No appointments this week."}
        </p>
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

    # Today-forward only: never show past days (a meeting from yesterday that was
    # never executed shouldn't appear as if it's still live).
    today = Florina.Tz.today()

    days =
      0..6 |> Enum.map(&Date.add(monday, &1)) |> Enum.filter(&(Date.compare(&1, today) != :lt))

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

  defp days_with_items(days, items, filter),
    do: Enum.filter(days, &(items_for(items, &1, filter) != []))

  defp items_for(items, day, filter) do
    items
    |> Enum.filter(fn i -> DateTime.to_date(Florina.Tz.local(i.start_time)) == day end)
    |> Enum.filter(fn i -> is_nil(filter) or i.agent_id == filter end)
  end

  defp today?(day), do: day == Florina.Tz.today()

  defp week_monday(date), do: Date.add(date, -(Date.day_of_week(date) - 1))

  defp week_range_label(monday),
    do:
      "#{Calendar.strftime(monday, "%d %b")} – #{Calendar.strftime(Date.add(monday, 6), "%d %b")}"

  defp time_range(%{start_time: s, end_time: e}) when not is_nil(e), do: "#{fmt(s)} – #{fmt(e)}"
  defp time_range(%{start_time: s}), do: fmt(s)

  defp fmt(%DateTime{} = dt), do: Calendar.strftime(Florina.Tz.local(dt), "%H:%M")

  defp status_label(:PLANNED), do: "Planned"
  defp status_label(:PRE_CALL_DONE), do: "Briefed"
  defp status_label(:IN_PROGRESS), do: "In progress"
  defp status_label(:POST_CALL_DONE), do: "Debriefed"
  defp status_label(:COMPLETE), do: "Complete"
  defp status_label(:MISSED), do: "Missed"
  defp status_label(other), do: to_string(other)

  defp status_tone(:COMPLETE), do: "bg-success/10 text-success"
  defp status_tone(:IN_PROGRESS), do: "bg-info/10 text-info"
  defp status_tone(:MISSED), do: "bg-base-200 text-base-content/40 line-through"
  defp status_tone(_), do: "bg-base-200 text-base-content/70"

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
