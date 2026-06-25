defmodule FlorinaWeb.ClientsLive do
  @moduledoc """
  Agent-facing, read-only client directory. Clients are shared tenant-wide (not
  per-agent), so every signed-in agent may browse them; editing is manager-only
  (see `FlorinaWeb.Manage.ClientLive`).
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}

  alias Florina.Clients

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :clients, Clients.list())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:clients}
    >
      <h1 class="text-2xl font-semibold mb-4">Clients</h1>
      <div class="overflow-hidden border border-base-300 rounded-lg">
        <table class="w-full text-sm text-left">
          <thead class="bg-base-200 text-xs uppercase tracking-wider text-base-content/60">
            <tr>
              <th class="px-4 py-3">Name</th>
              <th class="px-4 py-3">Domain</th>
              <th class="px-4 py-3">Industry</th>
              <th class="px-4 py-3">Status</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr :for={c <- @clients} class="hover:bg-base-200/50">
              <td class="px-4 py-3 font-medium">{c.name}</td>
              <td class="px-4 py-3">{c.domain}</td>
              <td class="px-4 py-3">{c.industry}</td>
              <td class="px-4 py-3">
                <span class="text-xs rounded px-2 py-0.5 bg-base-200">{to_string(c.status)}</span>
              </td>
            </tr>
            <tr :if={@clients == []}>
              <td colspan="4" class="px-4 py-6 text-center text-base-content/40 text-sm">
                No clients yet.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.agent_app>
    """
  end
end
