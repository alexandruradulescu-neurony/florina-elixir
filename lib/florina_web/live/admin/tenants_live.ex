defmodule FlorinaWeb.Admin.TenantsLive do
  @moduledoc """
  Operator admin: list all tenants + add-tenant form.

  No tenant resolution — uses Florina.Repo (control-plane) directly.
  Provisioning is enqueued as an Oban job; status shows provisioning → active/failed.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.Admin.AdminAuth

  alias Florina.Tenants
  alias Florina.Workers.ProvisionTenant

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:tenants, Tenants.list())
     |> assign(:form, build_form())}
  end

  @impl true
  def handle_event("validate", %{"tenant" => params}, socket) do
    params = maybe_suggest_database(params)
    {:noreply, assign(socket, :form, to_form(params, as: :tenant))}
  end

  def handle_event("add_tenant", %{"tenant" => params}, socket) do
    params = maybe_suggest_database(params)

    with :ok <- validate_slug(params["slug"]),
         :ok <- check_slug_unique(params["slug"]) do
      register_attrs = %{
        slug: params["slug"],
        name: params["name"],
        database: params["database"],
        status: "provisioning",
        active: true
      }

      case Tenants.register(register_attrs) do
        {:ok, _tenant} ->
          %{
            "slug" => params["slug"],
            "name" => params["name"],
            "database" => params["database"]
          }
          |> ProvisionTenant.new()
          |> Oban.insert()

          {:noreply,
           socket
           |> put_flash(:info, "Tenant #{params["slug"]} registered — provisioning started.")
           |> assign(:tenants, Tenants.list())
           |> assign(:form, build_form())}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Could not register tenant: #{format_errors(changeset)}")
           |> assign(:form, to_form(params, as: :tenant))}
      end
    else
      {:error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, msg)
         |> assign(:form, to_form(params, as: :tenant))}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :tenants, Tenants.list())}
  end

  def handle_event("deactivate", %{"slug" => slug}, socket) do
    Tenants.set_active(slug, false)

    {:noreply,
     socket
     |> put_flash(:info, "Tenant #{slug} deactivated.")
     |> assign(:tenants, Tenants.list())}
  end

  def handle_event("activate", %{"slug" => slug}, socket) do
    Tenants.set_active(slug, true)

    {:noreply,
     socket
     |> put_flash(:info, "Tenant #{slug} activated.")
     |> assign(:tenants, Tenants.list())}
  end

  def handle_event("save_domains", %{"slug" => slug, "domains" => raw}, socket) do
    domains = String.split(raw, [",", " ", "\n"], trim: true)

    case Tenants.set_allowed_domains(slug, domains) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Updated allowed domains for #{slug}.")
         |> assign(:tenants, Tenants.list())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update domains for #{slug}.")}
    end
  end

  def handle_event("retry", %{"slug" => slug}, socket) do
    case Tenants.get_by_slug(slug) do
      nil ->
        {:noreply, put_flash(socket, :error, "Tenant #{slug} not found.")}

      tenant ->
        Tenants.set_status(slug, "provisioning")

        %{"slug" => tenant.slug, "name" => tenant.name, "database" => tenant.database}
        |> ProvisionTenant.new()
        |> Oban.insert()

        {:noreply,
         socket
         |> put_flash(:info, "Re-provisioning #{slug}…")
         |> assign(:tenants, Tenants.list())}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-5xl mx-auto">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-semibold">Tenants</h1>
            <p class="text-sm text-gray-500 mt-1">
              <a href="/admin" class="hover:underline">Admin</a> &rsaquo; Tenants
            </p>
          </div>
          <div class="flex gap-2">
            <a href="/admin/config" class="px-3 py-1.5 text-sm border rounded hover:bg-gray-50">
              Config
            </a>
            <button
              phx-click="refresh"
              class="px-3 py-1.5 text-sm border rounded hover:bg-gray-50"
            >
              Refresh
            </button>
          </div>
        </div>

        <%!-- Tenant table --%>
        <div class="overflow-hidden border rounded-lg mb-10">
          <table class="w-full text-sm text-left">
            <thead class="bg-gray-50 text-xs uppercase tracking-wider text-gray-500">
              <tr>
                <th class="px-4 py-3">Name</th>
                <th class="px-4 py-3">Slug</th>
                <th class="px-4 py-3">Database</th>
                <th class="px-4 py-3">Status</th>
                <th class="px-4 py-3">Active</th>
                <th class="px-4 py-3">Domains</th>
                <th class="px-4 py-3">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y">
              <tr :for={tenant <- @tenants} class="hover:bg-gray-50">
                <td class="px-4 py-3 font-medium">{tenant.name}</td>
                <td class="px-4 py-3 font-mono text-xs">{tenant.slug}</td>
                <td class="px-4 py-3 font-mono text-xs">{tenant.database}</td>
                <td class="px-4 py-3">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    tenant.status == "active" && "bg-green-100 text-green-800",
                    tenant.status == "provisioning" && "bg-yellow-100 text-yellow-800",
                    tenant.status == "failed" && "bg-red-100 text-red-800"
                  ]}>
                    {tenant.status}
                  </span>
                </td>
                <td class="px-4 py-3">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    tenant.active && "bg-blue-100 text-blue-800",
                    !tenant.active && "bg-gray-100 text-gray-500"
                  ]}>
                    {if tenant.active, do: "yes", else: "no"}
                  </span>
                </td>
                <td class="px-4 py-3">
                  <form id={"domains-#{tenant.slug}"} phx-submit="save_domains" class="flex gap-1">
                    <input type="hidden" name="slug" value={tenant.slug} />
                    <input
                      type="text"
                      name="domains"
                      value={Enum.join(tenant.allowed_email_domains || [], ", ")}
                      placeholder="leadder.com, acme.io"
                      class="border rounded px-2 py-1 text-xs font-mono w-48"
                    />
                    <button class="text-xs text-blue-600 hover:underline">Save</button>
                  </form>
                </td>
                <td class="px-4 py-3">
                  <a
                    href={"/admin/tenants/#{tenant.slug}/agents"}
                    class="text-xs text-blue-600 hover:underline mr-2"
                  >
                    Agents
                  </a>
                  <button
                    :if={tenant.active}
                    phx-click="deactivate"
                    phx-value-slug={tenant.slug}
                    class="text-xs text-red-600 hover:underline"
                    data-confirm={"Deactivate #{tenant.slug}?"}
                  >
                    Deactivate
                  </button>
                  <button
                    :if={!tenant.active}
                    phx-click="activate"
                    phx-value-slug={tenant.slug}
                    class="text-xs text-green-600 hover:underline"
                  >
                    Activate
                  </button>
                  <button
                    :if={tenant.status == "failed"}
                    phx-click="retry"
                    phx-value-slug={tenant.slug}
                    class="text-xs text-blue-600 hover:underline ml-2"
                    data-confirm={"Retry provisioning #{tenant.slug}?"}
                  >
                    Retry
                  </button>
                </td>
              </tr>
              <tr :if={@tenants == []}>
                <td colspan="7" class="px-4 py-6 text-center text-gray-400 text-sm">
                  No tenants yet.
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Add tenant form --%>
        <div class="border rounded-lg p-6 max-w-lg">
          <h2 class="text-lg font-medium mb-4">Add tenant</h2>
          <.form
            for={@form}
            id="add-tenant-form"
            phx-submit="add_tenant"
            phx-change="validate"
            class="space-y-4"
          >
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Display name</label>
              <input
                type="text"
                name="tenant[name]"
                value={@form[:name] && @form[:name].value}
                placeholder="Acme Corp"
                class="w-full border rounded px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-blue-500"
                required
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Slug</label>
              <input
                type="text"
                name="tenant[slug]"
                value={@form[:slug] && @form[:slug].value}
                placeholder="acme"
                pattern="[a-z0-9_-]+"
                title="Lowercase letters, digits, hyphens and underscores only"
                class="w-full border rounded px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-blue-500"
                required
              />
              <p class="text-xs text-gray-400 mt-1">Lowercase, URL-safe (a-z, 0-9, -, _)</p>
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Database name</label>
              <input
                type="text"
                name="tenant[database]"
                value={@form[:database] && @form[:database].value}
                placeholder="florina_tenant_acme"
                class="w-full border rounded px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-blue-500"
                required
              />
              <p class="text-xs text-gray-400 mt-1">Auto-suggested from slug; edit if needed.</p>
            </div>
            <button
              type="submit"
              class="px-4 py-2 bg-blue-600 text-white text-sm rounded hover:bg-blue-700 focus:outline-none"
            >
              Register &amp; provision
            </button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_form do
    to_form(%{"name" => "", "slug" => "", "database" => ""}, as: :tenant)
  end

  # Auto-suggest the database name from the slug if the database field is empty
  # or still matches the previous auto-suggestion pattern.
  defp maybe_suggest_database(%{"slug" => slug} = params) do
    current_db = params["database"] || ""
    suggested = "florina_tenant_#{slug}"

    if current_db == "" or String.starts_with?(current_db, "florina_tenant_") do
      Map.put(params, "database", suggested)
    else
      params
    end
  end

  defp validate_slug(nil), do: {:error, "Slug is required."}
  defp validate_slug(""), do: {:error, "Slug is required."}

  defp validate_slug(slug) do
    if Regex.match?(~r/\A[a-z0-9_-]+\z/, slug) do
      :ok
    else
      {:error, "Slug must be lowercase letters, digits, hyphens, or underscores only."}
    end
  end

  defp check_slug_unique(slug) do
    if Tenants.get_by_slug(slug) do
      {:error, "A tenant with slug \"#{slug}\" already exists."}
    else
      :ok
    end
  end

  defp format_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end
end
