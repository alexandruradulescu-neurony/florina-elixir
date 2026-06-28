defmodule FlorinaWeb.Admin.AgentsLive do
  @moduledoc """
  Operator admin: view + manage one tenant's *users* — promote/demote between
  manager and agent, and activate/deactivate.

  This is how the first manager is seeded: agents auto-create as `:agent` on
  their first SSO sign-in, so the operator flips one to `:manager` here; from
  then on managers manage the rest in-app. Reads/writes the tenant's own schema
  via `Tenants.with_prefix/2` (this LiveView is on the control-plane, not behind
  ResolveTenant, so it pins the prefix explicitly per operation).
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.Admin.AdminAuth

  alias Florina.{Accounts, Tenants}

  @impl true
  def mount(%{"tenant_slug" => slug}, _session, socket) do
    case Tenants.get_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Tenant #{slug} not found.")
         |> redirect(to: "/admin/tenants")}

      tenant ->
        {:ok, socket |> assign(:tenant, tenant) |> load_users()}
    end
  end

  @impl true
  def handle_event("set_role", %{"user_id" => id, "role" => role}, socket)
      when role in ["manager", "agent"] do
    {:noreply,
     with_user(socket, id, &Accounts.set_role(&1, String.to_existing_atom(role)), "Role updated.")}
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    {:noreply, with_user(socket, id, &Accounts.set_active(&1, !&1.active), "Updated.")}
  end

  # Run `fun` against the tenant's user `id` inside the tenant's schema, then reload.
  defp with_user(socket, id, fun, ok_msg) do
    result =
      Tenants.with_prefix(socket.assigns.tenant, fn ->
        case Accounts.get_user(id) do
          nil -> {:error, :not_found}
          user -> fun.(user)
        end
      end)

    case result do
      {:ok, _} -> socket |> put_flash(:info, ok_msg) |> load_users()
      {:error, :not_found} -> put_flash(socket, :error, "User not found.")
      {:error, _changeset} -> put_flash(socket, :error, "Could not update user.")
    end
  end

  defp load_users(socket) do
    tenant = socket.assigns.tenant

    if tenant.status == "active" do
      users = Tenants.with_prefix(tenant, fn -> Accounts.list_users() end)
      assign(socket, users: users, provisioned?: true)
    else
      assign(socket, users: [], provisioned?: false)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-4xl mx-auto">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-semibold text-gray-900 dark:text-white">
              Agents — {@tenant.name}
            </h1>
            <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
              <a href="/admin" class="hover:underline">Admin</a>
              &rsaquo; <a href="/admin/tenants" class="hover:underline">Tenants</a>
              &rsaquo; {@tenant.slug}
            </p>
          </div>
          <a
            href="/admin/tenants"
            class="px-3 py-1.5 text-sm font-semibold rounded-md bg-white text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"
          >
            Back
          </a>
        </div>

        <p
          :if={!@provisioned?}
          class="text-sm text-amber-700 bg-amber-50 border border-amber-200 rounded p-3 dark:text-amber-300 dark:bg-amber-500/10 dark:border-amber-500/20"
        >
          This tenant isn't provisioned yet — no users to show.
        </p>

        <div
          :if={@provisioned?}
          class="overflow-hidden border border-gray-200 rounded-lg dark:border-white/10"
        >
          <table class="w-full text-sm text-left">
            <thead class="bg-gray-50 text-xs uppercase tracking-wider text-gray-500 dark:bg-white/5 dark:text-gray-400">
              <tr>
                <th class="px-4 py-3 font-semibold">User</th>
                <th class="px-4 py-3 font-semibold">Email</th>
                <th class="px-4 py-3 font-semibold">Role</th>
                <th class="px-4 py-3 font-semibold">Active</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200 dark:divide-white/10">
              <tr :for={u <- @users} class="hover:bg-gray-50 dark:hover:bg-white/5">
                <td class="px-4 py-3 font-medium text-gray-900 dark:text-white">{u.username}</td>
                <td class="px-4 py-3 font-mono text-xs text-gray-700 dark:text-gray-300">
                  {u.email}
                </td>
                <td class="px-4 py-3">
                  <form phx-change="set_role">
                    <input type="hidden" name="user_id" value={u.id} />
                    <select
                      name="role"
                      class="rounded px-2 py-1 text-xs bg-white text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10"
                    >
                      <option value="agent" selected={u.role == :agent}>agent</option>
                      <option value="manager" selected={u.role == :manager}>manager</option>
                    </select>
                  </form>
                </td>
                <td class="px-4 py-3">
                  <button
                    phx-click="toggle_active"
                    phx-value-id={u.id}
                    class={[
                      "text-xs font-medium hover:underline",
                      (u.active && "text-red-600 dark:text-red-400") ||
                        "text-green-600 dark:text-green-400"
                    ]}
                  >
                    {if u.active, do: "Deactivate", else: "Activate"}
                  </button>
                  <span :if={!u.active} class="ml-2 text-xs text-gray-400">(inactive)</span>
                </td>
              </tr>
              <tr :if={@users == []}>
                <td colspan="4" class="px-4 py-6 text-center text-gray-400 text-sm">
                  No users yet — they appear here after their first sign-in.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
