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
        <h1 class="text-2xl font-semibold mb-6">Operator Admin</h1>
        <ul class="space-y-3">
          <li>
            <a href="/admin/tenants" class="text-blue-600 hover:underline text-lg font-medium">
              Tenants
            </a>
            <p class="text-sm text-gray-500">Register and manage tenants, monitor provisioning.</p>
          </li>
          <li>
            <a href="/admin/config" class="text-blue-600 hover:underline text-lg font-medium">
              Central Config
            </a>
            <p class="text-sm text-gray-500">
              Edit canonical prompts, methodologies, scenarios, and settings. Publish to all tenants.
            </p>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
