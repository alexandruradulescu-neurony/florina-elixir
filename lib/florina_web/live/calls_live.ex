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
      <.header micro="Calls">Calls</.header>
      <div class="overflow-x-auto rounded-lg border border-gray-200 bg-white dark:border-white/10 dark:bg-white/5">
        <table class="w-full text-left">
          <thead class="border-b border-gray-200 bg-gray-50 dark:border-white/10 dark:bg-white/5">
            <tr>
              <th class={th_class()}>Phase</th>
              <th class={th_class()}>Status</th>
              <th class={th_class()}>Call ID</th>
              <th class={th_class()}>Summary</th>
              <th class={th_class()}>Updated</th>
            </tr>
          </thead>
          <tbody id="calls" phx-update="stream" class="divide-y divide-gray-200 dark:divide-white/10">
            <tr
              :for={{dom_id, call} <- @streams.calls}
              id={dom_id}
              class="hover:bg-gray-50 dark:hover:bg-white/5"
            >
              <td class={td_class()}>
                <span class="rounded-full bg-gray-100 px-2 py-0.5 text-xs font-semibold text-gray-600 dark:bg-white/10 dark:text-gray-300">
                  {call.phase}
                </span>
              </td>
              <td class={td_class()}>{call.status}</td>
              <td class={[td_class(), "tabular-nums text-gray-500 dark:text-gray-400"]}>
                {call.external_call_id}
              </td>
              <td class={td_class()}>{call.summary}</td>
              <td class={[td_class(), "whitespace-nowrap text-gray-500 dark:text-gray-400"]}>
                {call.updated_at}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.agent_app>
    """
  end
end
