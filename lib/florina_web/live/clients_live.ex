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
      <h1 class="text-2xl font-semibold mb-4 text-gray-900 dark:text-white">Clients</h1>
      <div class="overflow-hidden border border-gray-200 rounded-lg dark:border-white/10">
        <table class="w-full text-sm text-left">
          <thead class="bg-gray-50 text-xs uppercase tracking-wider text-gray-500 dark:bg-white/5 dark:text-gray-400">
            <tr>
              <th class="px-4 py-3 font-semibold">Name</th>
              <th class="px-4 py-3 font-semibold">Domain</th>
              <th class="px-4 py-3 font-semibold">Industry</th>
              <th class="px-4 py-3 font-semibold">Status</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200 dark:divide-white/10">
            <tr :for={c <- @clients} class="hover:bg-gray-50 dark:hover:bg-white/5">
              <td class="px-4 py-3 font-medium text-gray-900 dark:text-white">{c.name}</td>
              <td class="px-4 py-3 text-gray-700 dark:text-gray-300">{c.domain}</td>
              <td class="px-4 py-3 text-gray-700 dark:text-gray-300">{c.industry}</td>
              <td class="px-4 py-3">
                <span class="text-xs rounded px-2 py-0.5 bg-gray-100 text-gray-600 dark:bg-white/10 dark:text-gray-300">
                  {to_string(c.status)}
                </span>
              </td>
            </tr>
            <tr :if={@clients == []}>
              <td colspan="4" class="px-4 py-6 text-center text-gray-400 text-sm">
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
