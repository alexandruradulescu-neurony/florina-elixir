defmodule FlorinaWeb.CalendarLive do
  @moduledoc "Merged calendar: every agent's appointments for a week, filterable by agent."
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}

  alias Florina.{Accounts, CalendarEvents}

  @impl true
  def mount(_params, _session, socket) do
    monday = week_monday(Date.utc_today())

    {:ok,
     socket
     |> assign(:agents, Accounts.list_agents())
     |> assign(:filter_agent_id, nil)
     |> load_week(monday)}
  end

  @impl true
  def handle_event("filter", %{"agent_id" => id}, socket) do
    {:noreply, assign(socket, :filter_agent_id, parse_id(id))}
  end

  def handle_event("prev_week", _params, socket),
    do: {:noreply, load_week(socket, Date.add(socket.assigns.monday, -7))}

  def handle_event("next_week", _params, socket),
    do: {:noreply, load_week(socket, Date.add(socket.assigns.monday, 7))}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:calendar}
    >
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-semibold">Calendar</h1>
        <div class="flex items-center gap-2">
          <form phx-change="filter">
            <select name="agent_id" class="border rounded px-2 py-1 text-sm">
              <option value="">All agents</option>
              <option :for={a <- @agents} value={a.id} selected={@filter_agent_id == a.id}>
                {agent_label(a)}
              </option>
            </select>
          </form>
          <button phx-click="prev_week" class="px-2 py-1 text-sm border rounded hover:bg-gray-50">←</button>
          <span class="text-sm text-gray-600">{week_range_label(@monday)}</span>
          <button phx-click="next_week" class="px-2 py-1 text-sm border rounded hover:bg-gray-50">→</button>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-7 gap-3">
        <div :for={day <- @days} class="border rounded-lg p-2 min-h-32">
          <div class="text-xs font-medium text-gray-500 mb-2">
            {Calendar.strftime(day, "%a %d %b")}
          </div>
          <div class="space-y-1">
            <div
              :for={ev <- events_for(@events, day, @filter_agent_id)}
              class="rounded px-2 py-1 text-xs bg-blue-50 border border-blue-100"
            >
              <div class="font-medium text-gray-800">{format_time(ev.start_time)} · {ev.title}</div>
              <div class="text-gray-500">{agent_label(ev.user)}</div>
            </div>
            <p :if={events_for(@events, day, @filter_agent_id) == []} class="text-xs text-gray-300">
              —
            </p>
          </div>
        </div>
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
    |> assign(:events, CalendarEvents.list_events_between(from, to))
  end

  defp events_for(events, day, filter) do
    events
    |> Enum.filter(fn e -> DateTime.to_date(e.start_time) == day end)
    |> Enum.filter(fn e -> is_nil(filter) or e.user_id == filter end)
  end

  defp week_monday(date), do: Date.add(date, -(Date.day_of_week(date) - 1))

  defp week_range_label(monday),
    do:
      "#{Calendar.strftime(monday, "%d %b")} – #{Calendar.strftime(Date.add(monday, 6), "%d %b")}"

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

  defp agent_label(nil), do: "—"

  defp agent_label(user) do
    name = [user.first_name, user.last_name] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
    if name == "", do: user.email || user.username, else: name
  end

  defp parse_id(""), do: nil
  defp parse_id(id), do: String.to_integer(id)
end
