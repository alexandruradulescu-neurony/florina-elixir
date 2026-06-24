defmodule FlorinaWeb.CallsLive do
  use FlorinaWeb, :live_view
  alias Florina.Calls

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Florina.PubSub, "calls")
    {:ok, stream(socket, :calls, Calls.list_recent())}
  end

  @impl true
  def handle_info({:call_updated, call}, socket) do
    {:noreply, stream_insert(socket, :calls, call, at: 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold mb-4">Calls</h1>
    <table class="w-full text-left">
      <thead>
        <tr>
          <th>Phase</th><th>Status</th><th>Call ID</th><th>Summary</th><th>Updated</th>
        </tr>
      </thead>
      <tbody id="calls" phx-update="stream">
        <tr :for={{dom_id, call} <- @streams.calls} id={dom_id}>
          <td>{call.phase}</td>
          <td>{call.status}</td>
          <td>{call.external_call_id}</td>
          <td>{call.summary}</td>
          <td>{call.updated_at}</td>
        </tr>
      </tbody>
    </table>
    """
  end
end
