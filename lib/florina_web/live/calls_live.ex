defmodule FlorinaWeb.CallsLive do
  use FlorinaWeb, :live_view
  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  alias Florina.{Authz, Calls}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Florina.PubSub, Calls.topic(socket.assigns.tenant.slug))

    agent = socket.assigns.current_agent

    {:ok,
     socket
     |> assign(:manager?, Authz.manager?(agent))
     |> assign(:agent_id, agent.id)
     |> stream(:calls, Calls.list_recent(Authz.scope(agent)))}
  end

  # Managers see every call; agents only see realtime updates for calls they own.
  @impl true
  def handle_info({:call_updated, call}, socket) do
    if socket.assigns.manager? or Calls.owned_by_agent?(call, socket.assigns.agent_id) do
      {:noreply, stream_insert(socket, :calls, call, at: 0)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app flash={@flash} tenant={@tenant} current_agent={@current_agent} active={:calls}>
      <h1 class="text-2xl font-semibold mb-4">Calls</h1>
      <table class="w-full text-left text-sm">
        <thead>
          <tr class="border-b border-base-300">
            <th class="px-3 py-2 font-semibold">Phase</th>
            <th class="px-3 py-2 font-semibold">Status</th>
            <th class="px-3 py-2 font-semibold">Call ID</th>
            <th class="px-3 py-2 font-semibold">Summary</th>
            <th class="px-3 py-2 font-semibold">Updated</th>
          </tr>
        </thead>
        <tbody id="calls" phx-update="stream">
          <tr
            :for={{dom_id, call} <- @streams.calls}
            id={dom_id}
            class="odd:bg-base-100 even:bg-base-200"
          >
            <td class="px-3 py-2">{call.phase}</td>
            <td class="px-3 py-2">{call.status}</td>
            <td class="px-3 py-2">{call.external_call_id}</td>
            <td class="px-3 py-2">{call.summary}</td>
            <td class="px-3 py-2">{call.updated_at}</td>
          </tr>
        </tbody>
      </table>
    </Layouts.agent_app>
    """
  end
end
