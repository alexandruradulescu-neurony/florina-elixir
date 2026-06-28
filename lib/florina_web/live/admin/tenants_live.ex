defmodule FlorinaWeb.Admin.TenantsLive do
  @moduledoc """
  Operator admin: list all tenants + add-tenant form.

  No tenant resolution — uses Florina.Repo (control-plane) directly.
  Provisioning is enqueued as an Oban job; status shows provisioning → active/failed.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.Admin.AdminAuth

  alias Florina.{Settings, Tenants}
  alias Florina.Workers.ProvisionTenant

  @impl true
  def mount(_params, _session, socket) do
    tenants = Tenants.list()

    {:ok,
     socket
     |> assign(:tenants, tenants)
     |> assign(:crm, load_crm(tenants))
     |> assign(:form, build_form())}
  end

  @impl true
  def handle_event("validate", %{"tenant" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :tenant))}
  end

  def handle_event("add_tenant", %{"tenant" => params}, socket) do
    with :ok <- validate_slug(params["slug"]),
         :ok <- check_slug_unique(params["slug"]) do
      register_attrs = %{
        slug: params["slug"],
        name: params["name"],
        status: "provisioning",
        active: true
      }

      case Tenants.register(register_attrs) do
        {:ok, _tenant} ->
          %{"slug" => params["slug"], "name" => params["name"]}
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

  def handle_event("save_crm", %{"slug" => slug} = params, socket) do
    case Tenants.get_by_slug(slug) do
      nil ->
        {:noreply, put_flash(socket, :error, "Tenant #{slug} not found.")}

      tenant ->
        result = with_tenant(tenant, fn -> Settings.update_crm(params) end)

        case result do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "CRM credentials saved for #{slug}.")
             |> assign(:crm, load_crm(socket.assigns.tenants))}

          _ ->
            {:noreply, put_flash(socket, :error, "Could not save CRM credentials for #{slug}.")}
        end
    end
  end

  def handle_event("retry", %{"slug" => slug}, socket) do
    case Tenants.get_by_slug(slug) do
      nil ->
        {:noreply, put_flash(socket, :error, "Tenant #{slug} not found.")}

      tenant ->
        Tenants.set_status(slug, "provisioning")

        %{"slug" => tenant.slug, "name" => tenant.name}
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
            <h1 class="text-2xl font-semibold text-gray-900 dark:text-white">Tenants</h1>
            <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
              <a href="/admin" class="hover:underline">Admin</a> &rsaquo; Tenants
            </p>
          </div>
          <div class="flex gap-2">
            <a
              href="/admin/config"
              class="px-3 py-1.5 text-sm font-semibold rounded-md bg-white text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"
            >
              Config
            </a>
            <button
              phx-click="refresh"
              class="px-3 py-1.5 text-sm font-semibold rounded-md bg-white text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"
            >
              Refresh
            </button>
          </div>
        </div>

        <%!-- Tenant table --%>
        <div class="overflow-hidden border border-gray-200 rounded-lg mb-10 dark:border-white/10">
          <table class="w-full text-sm text-left">
            <thead class="bg-gray-50 text-xs uppercase tracking-wider text-gray-500 dark:bg-white/5 dark:text-gray-400">
              <tr>
                <th class="px-4 py-3 font-semibold">Name</th>
                <th class="px-4 py-3 font-semibold">Slug</th>
                <th class="px-4 py-3 font-semibold">Status</th>
                <th class="px-4 py-3 font-semibold">Active</th>
                <th class="px-4 py-3 font-semibold">Domains</th>
                <th class="px-4 py-3 font-semibold">CRM</th>
                <th class="px-4 py-3 font-semibold">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200 dark:divide-white/10">
              <tr :for={tenant <- @tenants} class="hover:bg-gray-50 dark:hover:bg-white/5">
                <td class="px-4 py-3 font-medium text-gray-900 dark:text-white">{tenant.name}</td>
                <td class="px-4 py-3 font-mono text-xs text-gray-700 dark:text-gray-300">
                  {tenant.slug}
                </td>
                <td class="px-4 py-3">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    tenant.status == "active" &&
                      "bg-green-100 text-green-800 dark:bg-green-500/10 dark:text-green-400",
                    tenant.status == "provisioning" &&
                      "bg-yellow-100 text-yellow-800 dark:bg-yellow-500/10 dark:text-yellow-400",
                    tenant.status == "failed" &&
                      "bg-red-100 text-red-800 dark:bg-red-500/10 dark:text-red-400"
                  ]}>
                    {tenant.status}
                  </span>
                </td>
                <td class="px-4 py-3">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    tenant.active &&
                      "bg-blue-100 text-blue-800 dark:bg-blue-500/10 dark:text-blue-400",
                    !tenant.active && "bg-gray-100 text-gray-500 dark:bg-white/10 dark:text-gray-400"
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
                      class="rounded px-2 py-1 text-xs font-mono w-48 bg-white text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10"
                    />
                    <button class="text-xs font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400">
                      Save
                    </button>
                  </form>
                </td>
                <td class="px-4 py-3">
                  <form
                    :if={tenant.status == "active"}
                    id={"crm-#{tenant.slug}"}
                    phx-submit="save_crm"
                    class="flex flex-col gap-1"
                  >
                    <input type="hidden" name="slug" value={tenant.slug} />
                    <select
                      name="crm_provider"
                      class="rounded px-2 py-1 text-xs w-40 bg-white text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10"
                    >
                      <option
                        value="pipedrive"
                        selected={crm_provider(@crm, tenant.slug) == "pipedrive"}
                      >
                        Pipedrive
                      </option>
                      <option value="hubspot" selected={crm_provider(@crm, tenant.slug) == "hubspot"}>
                        HubSpot
                      </option>
                    </select>
                    <input
                      type="text"
                      name="pipedrive_domain"
                      value={crm_domain(@crm, tenant.slug)}
                      placeholder="Pipedrive domain"
                      class="rounded px-2 py-1 text-xs font-mono w-40 bg-white text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10"
                    />
                    <input
                      type="password"
                      name="pipedrive_api_token"
                      placeholder={token_ph(@crm, tenant.slug, :pd)}
                      class="rounded px-2 py-1 text-xs font-mono w-40 bg-white text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10"
                    />
                    <input
                      type="password"
                      name="hubspot_api_token"
                      placeholder={token_ph(@crm, tenant.slug, :hs)}
                      class="rounded px-2 py-1 text-xs font-mono w-40 bg-white text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10"
                    />
                    <button class="text-xs font-medium text-indigo-600 hover:text-indigo-500 self-start dark:text-indigo-400">
                      Save
                    </button>
                  </form>
                  <span :if={tenant.status != "active"} class="text-xs text-gray-400">—</span>
                </td>
                <td class="px-4 py-3">
                  <a
                    href={"/admin/tenants/#{tenant.slug}/agents"}
                    class="text-xs font-medium text-indigo-600 hover:text-indigo-500 mr-2 dark:text-indigo-400"
                  >
                    Agents
                  </a>
                  <button
                    :if={tenant.active}
                    phx-click="deactivate"
                    phx-value-slug={tenant.slug}
                    class="text-xs font-medium text-red-600 hover:text-red-500 dark:text-red-400"
                    data-confirm={"Deactivate #{tenant.slug}?"}
                  >
                    Deactivate
                  </button>
                  <button
                    :if={!tenant.active}
                    phx-click="activate"
                    phx-value-slug={tenant.slug}
                    class="text-xs font-medium text-green-600 hover:text-green-500 dark:text-green-400"
                  >
                    Activate
                  </button>
                  <button
                    :if={tenant.status == "failed"}
                    phx-click="retry"
                    phx-value-slug={tenant.slug}
                    class="text-xs font-medium text-indigo-600 hover:text-indigo-500 ml-2 dark:text-indigo-400"
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
        <div class="border border-gray-200 rounded-lg p-6 max-w-lg dark:border-white/10">
          <h2 class="text-lg font-medium mb-4 text-gray-900 dark:text-white">Add tenant</h2>
          <.form
            for={@form}
            id="add-tenant-form"
            phx-submit="add_tenant"
            phx-change="validate"
            class="space-y-4"
          >
            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Display name
              </label>
              <input
                type="text"
                name="tenant[name]"
                value={@form[:name] && @form[:name].value}
                placeholder="Acme Corp"
                class={admin_input()}
                required
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Slug
              </label>
              <input
                type="text"
                name="tenant[slug]"
                value={@form[:slug] && @form[:slug].value}
                placeholder="acme"
                pattern="[a-z0-9_-]+"
                title="Lowercase letters, digits, hyphens and underscores only"
                class={[admin_input(), "font-mono"]}
                required
              />
              <p class="text-xs text-gray-400 mt-1">Lowercase, URL-safe (a-z, 0-9, -, _)</p>
            </div>
            <button
              type="submit"
              class="px-4 py-2 bg-indigo-600 text-white text-sm font-semibold rounded-md shadow-xs hover:bg-indigo-500 dark:bg-indigo-500 dark:hover:bg-indigo-400"
            >
              Register &amp; provision
            </button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Shared TW Plus text-input styling for the admin add-tenant form.
  defp admin_input,
    do:
      "w-full rounded-md bg-white px-3 py-2 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 placeholder:text-gray-400 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500"

  # ---------------------------------------------------------------------------
  # CRM credentials (per-tenant, read/written inside the tenant's schema)
  # ---------------------------------------------------------------------------

  # Load each active tenant's CRM settings by briefly pinning its schema prefix.
  # Inactive/provisioning tenants have no usable schema yet, so they're skipped.
  defp load_crm(tenants) do
    for t <- tenants, t.status == "active", into: %{} do
      {t.slug, read_crm(t)}
    end
  end

  defp read_crm(tenant) do
    with_tenant(tenant, fn ->
      s = Settings.get()

      %{
        provider: s.crm_provider || "pipedrive",
        domain: s.pipedrive_domain,
        has_pd_token: present?(s.pipedrive_api_token),
        has_hs_token: present?(s.hubspot_api_token)
      }
    end)
  rescue
    _ -> %{provider: "pipedrive", domain: nil, has_pd_token: false, has_hs_token: false}
  end

  # Run `fun` with the tenant's schema prefix pinned, always clearing it after so
  # this long-lived LiveView process can't leak the prefix into later work.
  defp with_tenant(tenant, fun) do
    Process.put(:tenant_prefix, Tenants.schema_prefix(tenant))

    try do
      fun.()
    after
      Process.delete(:tenant_prefix)
    end
  end

  defp crm_domain(crm, slug), do: get_in(crm, [slug, :domain]) || ""
  defp crm_provider(crm, slug), do: get_in(crm, [slug, :provider]) || "pipedrive"

  defp token_ph(crm, slug, which) do
    key = if which == :pd, do: :has_pd_token, else: :has_hs_token

    if get_in(crm, [slug, key]),
      do: "•••••• (set — blank keeps it)",
      else: if(which == :pd, do: "Pipedrive token", else: "HubSpot token")
  end

  defp present?(v) when v in [nil, ""], do: false
  defp present?(_), do: true

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_form do
    to_form(%{"name" => "", "slug" => ""}, as: :tenant)
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
