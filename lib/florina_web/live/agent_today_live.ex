defmodule FlorinaWeb.AgentTodayLive do
  @moduledoc """
  An agent's own meetings for today, with a "have Florina call me" action that
  triggers the post-call debrief for a meeting (in case the scheduled daily call
  was missed). Scoped to the signed-in agent — they only ever see/act on their
  own meetings.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}

  alias Florina.Visits
  alias Florina.Workers.DialCall

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("call_me", %{"visit_id" => id}, socket) do
    id = String.to_integer(id)

    # Security: only allow a debrief for a meeting in the agent's own loaded list.
    if Enum.any?(socket.assigns.meetings, &(&1.id == id)) do
      %{"visit_id" => id, "phase" => "POST", "tenant_slug" => socket.assigns.tenant.slug}
      |> DialCall.new()
      |> Oban.insert()

      {:noreply, put_flash(socket, :info, "Florina will call you shortly for the debrief.")}
    else
      {:noreply, put_flash(socket, :error, "That meeting isn't one of yours.")}
    end
  end

  defp load(socket) do
    agent = socket.assigns.current_agent
    assign(socket, :meetings, Visits.list_for_agent_day(agent.id, Date.utc_today()))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app flash={@flash} tenant={@tenant} current_agent={@current_agent} active={:today}>
      <h1 class="text-2xl font-semibold mb-1">My day</h1>
      <p class="text-sm text-base-content/60 mb-6">
        {Calendar.strftime(Date.utc_today(), "%A, %d %B %Y")}
      </p>

      <div class="space-y-3 max-w-2xl">
        <div
          :for={v <- @meetings}
          class="flex items-center justify-between rounded-lg border border-base-300 bg-base-100 px-4 py-3"
        >
          <div>
            <div class="text-sm font-medium text-base-content">{time(v.start_time)} · {v.title}</div>
            <div class="text-xs text-base-content/60">
              {client_label(v.client)} ·
              <span class="rounded bg-base-200 px-2 py-0.5">{to_string(v.status)}</span>
            </div>
          </div>
          <button
            phx-click="call_me"
            phx-value-visit_id={v.id}
            class="inline-flex items-center gap-1 rounded-md bg-primary px-3 py-1.5 text-xs font-semibold text-primary-content hover:opacity-90 cursor-pointer"
          >
            <.icon name="hero-phone" class="size-4" /> Have Florina call me
          </button>
        </div>
        <p :if={@meetings == []} class="text-sm text-base-content/40">No meetings today.</p>
      </div>
    </Layouts.agent_app>
    """
  end

  defp time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp client_label(%{name: n}) when is_binary(n), do: n
  defp client_label(_), do: "—"
end
