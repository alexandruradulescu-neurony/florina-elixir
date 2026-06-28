defmodule FlorinaWeb.Admin.IndexLive do
  @moduledoc "Admin root — just links to the two sub-pages."
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.Admin.AdminAuth

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-xl mx-auto">
        <h1 class="text-2xl font-semibold mb-6 text-gray-900 dark:text-white">Operator Admin</h1>
        <ul class="space-y-3">
          <li>
            <a
              href="/admin/tenants"
              class="text-indigo-600 hover:text-indigo-500 text-lg font-medium dark:text-indigo-400"
            >
              Tenants
            </a>
            <p class="text-sm text-gray-500 dark:text-gray-400">
              Register and manage tenants, monitor provisioning.
            </p>
          </li>
          <li>
            <a
              href="/admin/config"
              class="text-indigo-600 hover:text-indigo-500 text-lg font-medium dark:text-indigo-400"
            >
              Central Config
            </a>
            <p class="text-sm text-gray-500 dark:text-gray-400">
              Edit canonical prompts, methodologies, scenarios, and settings. Publish to all tenants.
            </p>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
