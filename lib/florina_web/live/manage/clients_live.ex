defmodule FlorinaWeb.Manage.ClientsLive do
  @moduledoc "Manager view of every client in the tenant. Managers only."
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

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
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-semibold text-gray-900 dark:text-white">Clients</h1>
        <.button navigate={"/t/#{@tenant.slug}/manage/clients/new"} variant="primary">
          New client
        </.button>
      </div>
      <div class="overflow-hidden border border-gray-200 rounded-lg dark:border-white/10">
        <table class="w-full text-sm text-left">
          <thead class="bg-gray-50 text-xs uppercase tracking-wider text-gray-500 dark:bg-white/5 dark:text-gray-400">
            <tr>
              <th class="px-4 py-3 font-semibold">Name</th>
              <th class="px-4 py-3 font-semibold">Domain</th>
              <th class="px-4 py-3 font-semibold">Industry</th>
              <th class="px-4 py-3 font-semibold">Status</th>
              <th class="px-4 py-3"></th>
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
              <td class="px-4 py-3 text-right">
                <.link
                  navigate={"/t/#{@tenant.slug}/manage/clients/#{c.id}"}
                  class="text-sm font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
                >
                  Edit
                </.link>
              </td>
            </tr>
            <tr :if={@clients == []}>
              <td colspan="5" class="px-4 py-6 text-center text-gray-400 text-sm">
                No clients yet — they appear here as meetings sync from your CRM.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.agent_app>
    """
  end
end
