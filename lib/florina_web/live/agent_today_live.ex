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
    # `id` is a client-sent param; a non-integer is ignored rather than crashing.
    # Re-fetch the visit and check ownership AT EVENT TIME (not the list captured
    # at mount) — a meeting reassigned to another agent after mount must not be
    # actionable by the original agent.
    agent_id = socket.assigns.current_agent.id

    with {visit_id, ""} <- Integer.parse(to_string(id)),
         %Visits.Visit{agent_id: ^agent_id} <- Visits.get(visit_id) do
      %{
        "visit_id" => visit_id,
        "phase" => "POST",
        "tenant_slug" => socket.assigns.tenant.slug,
        # Explicit human request — dial even outside the scheduled call window.
        "manual" => true
      }
      |> DialCall.new()
      |> Oban.insert()

      {:noreply, put_flash(socket, :info, "Florina will call you shortly for the debrief.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "That meeting isn't one of yours.")}
    end
  end

  defp load(socket) do
    agent = socket.assigns.current_agent
    assign(socket, :meetings, Visits.list_for_agent_day(agent.id, Florina.Tz.today()))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app flash={@flash} tenant={@tenant} current_agent={@current_agent} active={:today}>
      <.header micro="Today">
        My day
        <:subtitle>{Calendar.strftime(Florina.Tz.today(), "%A, %d %B %Y")}</:subtitle>
      </.header>

      <div class="space-y-3 max-w-2xl">
        <div
          :for={v <- @meetings}
          class="flex items-center justify-between gap-4 rounded-lg border border-gray-200 bg-white px-4 py-3 dark:border-white/10 dark:bg-white/5"
        >
          <div class="min-w-0">
            <div class="text-sm font-medium text-gray-900 dark:text-white">
              {time(v.start_time)} · {v.title}
            </div>
            <div class="text-xs text-gray-500 dark:text-gray-400 flex items-center gap-2 mt-0.5">
              <span>{client_label(v.client)}</span>
              <span class={["rounded-full px-2 py-0.5 font-medium", status_tone(v.status)]}>
                {status_label(v.status)}
              </span>
            </div>
          </div>
          <button
            phx-click="call_me"
            phx-value-visit_id={v.id}
            class="inline-flex shrink-0 items-center gap-1 rounded-full bg-indigo-600 px-4 py-1.5 text-xs font-bold text-white hover:bg-indigo-500 cursor-pointer dark:bg-indigo-500 dark:hover:bg-indigo-400"
          >
            <.icon name="hero-phone" class="size-4" /> Have Florina call me
          </button>
        </div>

        <p
          :if={@meetings == []}
          class="text-sm text-gray-500 dark:text-gray-400 rounded-lg border border-dashed border-gray-300 px-4 py-8 text-center dark:border-white/15"
        >
          Nothing on your calendar today. Meetings appear here automatically once your calendar syncs.
        </p>
      </div>
    </Layouts.agent_app>
    """
  end

  defp time(%DateTime{} = dt), do: Florina.Tz.format(dt, :time)

  defp status_label(status), do: visit_status_label(status)
  defp status_tone(status), do: visit_status_tone(status)

  defp client_label(%{name: n}) when is_binary(n), do: n
  defp client_label(_), do: "—"
end
