defmodule FlorinaWeb.Manage.DashboardLive do
  @moduledoc """
  Manager dashboard — a live snapshot of the tenant's day: today's meetings
  across every agent and recent call activity, updating in real time as calls
  progress (subscribes to the tenant calls topic). Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Calls, Visits}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Florina.PubSub, Calls.topic(socket.assigns.tenant.slug))

    {:ok, load(socket)}
  end

  @impl true
  def handle_info({:call_updated, _call}, socket) do
    {:noreply, assign(socket, :recent_calls, Calls.list_recent(:all, 15))}
  end

  defp load(socket) do
    today = Date.utc_today()

    socket
    |> assign(:today, today)
    |> assign(:meetings, Visits.list_for_day(today))
    |> assign(:recent_calls, Calls.list_recent(:all, 15))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:dashboard}
    >
      <h1 class="text-2xl font-semibold mb-1">Dashboard</h1>
      <p class="text-sm text-base-content/60 mb-6">{Calendar.strftime(@today, "%A, %d %B %Y")}</p>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-8">
        <.stat label="Meetings today" value={length(@meetings)} />
        <.stat label="Completed" value={Enum.count(@meetings, &(&1.status == :COMPLETE))} />
        <.stat label="Recent calls" value={length(@recent_calls)} />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <section>
          <h2 class="text-lg font-medium mb-3">Today's meetings</h2>
          <div class="space-y-2">
            <div
              :for={v <- @meetings}
              class="flex items-center justify-between rounded-lg border border-base-300 px-3 py-2"
            >
              <div>
                <div class="text-sm font-medium text-base-content">
                  {time(v.start_time)} · {v.title}
                </div>
                <div class="text-xs text-base-content/60">
                  {agent_label(v.agent)} · {client_label(v.client)}
                </div>
              </div>
              <span class="text-xs rounded px-2 py-0.5 bg-base-200 text-base-content/70">
                {to_string(v.status)}
              </span>
            </div>
            <p :if={@meetings == []} class="text-sm text-base-content/40">No meetings today.</p>
          </div>
        </section>

        <section>
          <h2 class="text-lg font-medium mb-3">Recent call activity</h2>
          <div class="space-y-2">
            <div :for={c <- @recent_calls} class="rounded-lg border border-base-300 px-3 py-2">
              <div class="flex items-center justify-between">
                <span class="text-sm font-medium">{c.phase} call</span>
                <span class="text-xs rounded px-2 py-0.5 bg-base-200 text-base-content/70">
                  {c.status}
                </span>
              </div>
              <div :if={c.summary_title} class="text-xs text-base-content/60 mt-0.5">
                {c.summary_title}
              </div>
            </div>
            <p :if={@recent_calls == []} class="text-sm text-base-content/40">
              No call activity yet.
            </p>
          </div>
        </section>
      </div>
    </Layouts.agent_app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 px-4 py-3">
      <div class="text-2xl font-semibold text-base-content">{@value}</div>
      <div class="text-xs text-base-content/60">{@label}</div>
    </div>
    """
  end

  defp time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

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
end
