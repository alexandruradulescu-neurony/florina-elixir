defmodule FlorinaWeb.CalendarLive do
  @moduledoc """
  Upcoming appointments for a week, as a day-by-day agenda. Managers see every
  agent's events and can filter by agent; agents see only their own (scoped in
  SQL via `Florina.Authz`).
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}

  alias Florina.{Accounts, Authz, CalendarEvents}

  @impl true
  def mount(_params, _session, socket) do
    monday = week_monday(Date.utc_today())
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
    do: {:noreply, load_week(socket, week_monday(Date.utc_today()))}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:calendar}
    >
      <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
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

      <div class="space-y-6 max-w-2xl">
        <section :for={day <- days_with_events(@days, @events, @filter_agent_id)}>
          <h2 class={[
            "text-sm font-semibold mb-2",
            (today?(day) && "text-primary") || "text-base-content/60"
          ]}>
            {Calendar.strftime(day, "%A, %d %B")}{if today?(day), do: " · Today"}
          </h2>
          <div class="space-y-2">
            <div
              :for={ev <- events_for(@events, day, @filter_agent_id)}
              class="flex items-center gap-3 rounded-lg border border-base-300 px-3 py-2"
            >
              <div class="text-sm font-medium text-base-content/80 w-28 shrink-0">
                {time_range(ev)}
              </div>
              <div class="min-w-0">
                <div class="text-sm font-medium truncate">{ev.title}</div>
                <div :if={@manager?} class="text-xs text-base-content/50">{agent_label(ev.user)}</div>
              </div>
            </div>
          </div>
        </section>

        <p
          :if={days_with_events(@days, @events, @filter_agent_id) == []}
          class="text-sm text-base-content/50 rounded-lg border border-dashed border-base-300 px-4 py-8 text-center"
        >
          No appointments this week.
        </p>
      </div>
    </Layouts.agent_app>
    """
  end

  defp load_week(socket, monday) do
    from = DateTime.new!(monday, ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(Date.add(monday, 6), ~T[23:59:59], "Etc/UTC")

    socket
    |> assign(:monday, monday)
    |> assign(:days, Enum.map(0..6, &Date.add(monday, &1)))
    |> assign(:events, CalendarEvents.list_events_between(from, to, socket.assigns.scope))
  end

  defp days_with_events(days, events, filter),
    do: Enum.filter(days, &(events_for(events, &1, filter) != []))

  defp events_for(events, day, filter) do
    events
    |> Enum.filter(fn e -> DateTime.to_date(e.start_time) == day end)
    |> Enum.filter(fn e -> is_nil(filter) or e.user_id == filter end)
  end

  defp today?(day), do: day == Date.utc_today()

  defp week_monday(date), do: Date.add(date, -(Date.day_of_week(date) - 1))

  defp week_range_label(monday),
    do:
      "#{Calendar.strftime(monday, "%d %b")} – #{Calendar.strftime(Date.add(monday, 6), "%d %b")}"

  defp time_range(%{start_time: s, end_time: e}) when not is_nil(e),
    do: "#{fmt(s)} – #{fmt(e)}"

  defp time_range(%{start_time: s}), do: fmt(s)

  defp fmt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

  defp agent_label(nil), do: "—"

  defp agent_label(user) do
    name = [user.first_name, user.last_name] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
    if name == "", do: user.email || user.username, else: name
  end

  defp parse_id(""), do: nil
  defp parse_id(id), do: String.to_integer(id)
end
