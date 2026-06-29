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
      <h1 class="text-2xl font-semibold mb-1 text-gray-900 dark:text-white">My day</h1>
      <p class="text-sm text-gray-500 dark:text-gray-400 mb-6">
        {Calendar.strftime(Florina.Tz.today(), "%A, %d %B %Y")}
      </p>

      <div class="space-y-3 max-w-2xl">
        <div
          :for={v <- @meetings}
          class="flex items-center justify-between gap-4 rounded-lg border border-gray-200 bg-white px-4 py-3 dark:border-white/10 dark:bg-gray-900"
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
            class="inline-flex shrink-0 items-center gap-1 rounded-md bg-indigo-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-indigo-500 cursor-pointer dark:bg-indigo-500 dark:hover:bg-indigo-400"
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

  defp time(%DateTime{} = dt), do: Calendar.strftime(Florina.Tz.local(dt), "%H:%M")

  defp status_label(:PLANNED), do: "Planned"
  defp status_label(:PRE_CALL_DONE), do: "Briefed"
  defp status_label(:IN_PROGRESS), do: "In progress"
  defp status_label(:POST_CALL_DONE), do: "Debriefed"
  defp status_label(:COMPLETE), do: "Complete"
  defp status_label(:CANCELLED), do: "Cancelled"
  defp status_label(:MISSED), do: "Missed"
  defp status_label(other), do: to_string(other)

  defp status_tone(:COMPLETE),
    do: "bg-green-100 text-green-700 dark:bg-green-500/10 dark:text-green-400"

  defp status_tone(:IN_PROGRESS),
    do: "bg-blue-100 text-blue-700 dark:bg-blue-500/10 dark:text-blue-400"

  defp status_tone(s) when s in [:CANCELLED, :MISSED],
    do: "bg-gray-100 text-gray-400 line-through dark:bg-white/5 dark:text-gray-500"

  defp status_tone(_), do: "bg-gray-100 text-gray-600 dark:bg-white/10 dark:text-gray-300"

  defp client_label(%{name: n}) when is_binary(n), do: n
  defp client_label(_), do: "—"
end
