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
      <.header micro="Manage">
        Clients
        <:actions>
          <.button navigate={"/t/#{@tenant.slug}/manage/clients/new"} variant="primary">
            New client
          </.button>
        </:actions>
      </.header>
      <div class="overflow-hidden rounded-lg border border-gray-200 bg-white dark:border-white/10 dark:bg-white/5">
        <table class="w-full text-left">
          <thead class="border-b border-gray-200 bg-gray-50 dark:border-white/10 dark:bg-white/5">
            <tr>
              <th class={th_class()}>Name</th>
              <th class={th_class()}>Domain</th>
              <th class={th_class()}>Industry</th>
              <th class={th_class()}>Status</th>
              <th class={th_class()}></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200 dark:divide-white/10">
            <tr :for={c <- @clients} class="hover:bg-gray-50 dark:hover:bg-white/5">
              <td class={[td_class(), "font-bold text-gray-900 dark:text-white"]}>{c.name}</td>
              <td class={td_class()}>{c.domain}</td>
              <td class={td_class()}>{c.industry}</td>
              <td class={td_class()}>
                <span class="rounded-full bg-gray-100 px-2 py-0.5 text-xs font-semibold text-gray-600 dark:bg-white/10 dark:text-gray-300">
                  {String.capitalize(to_string(c.status))}
                </span>
              </td>
              <td class={[td_class(), "text-right"]}>
                <.link
                  navigate={"/t/#{@tenant.slug}/manage/clients/#{c.id}"}
                  class="text-sm font-bold text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
                >
                  Edit
                </.link>
              </td>
            </tr>
            <tr :if={@clients == []}>
              <td colspan="5" class="px-4 py-10 text-center text-sm text-gray-400">
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
