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
        <.header micro="Operator">Operator Admin</.header>
        <ul class="space-y-3">
          <li>
            <a
              href="/admin/tenants"
              class="block rounded-lg border border-gray-200 bg-white p-5 transition-colors hover:border-gray-300 dark:border-white/10 dark:bg-white/5 dark:hover:border-white/20"
            >
              <div class="text-lg font-extrabold text-indigo-600 dark:text-indigo-400">Tenants</div>
              <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                Register and manage tenants, monitor provisioning.
              </p>
            </a>
          </li>
          <li>
            <a
              href="/admin/config"
              class="block rounded-lg border border-gray-200 bg-white p-5 transition-colors hover:border-gray-300 dark:border-white/10 dark:bg-white/5 dark:hover:border-white/20"
            >
              <div class="text-lg font-extrabold text-indigo-600 dark:text-indigo-400">
                Central Config
              </div>
              <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                Edit canonical prompts, methodologies, scenarios, and settings. Publish to all tenants.
              </p>
            </a>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
