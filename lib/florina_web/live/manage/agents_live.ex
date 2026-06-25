defmodule FlorinaWeb.Manage.AgentsLive do
  @moduledoc """
  Manager management of the tenant's people: promote/demote between manager and
  agent, and activate/deactivate. Managers only. Guards against removing the
  last active manager (which would lock everyone out of the management area).
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_users(socket)}
  end

  @impl true
  def handle_event("set_role", %{"user_id" => id, "role" => role}, socket)
      when role in ["manager", "agent"] do
    user = Accounts.get_user(id)

    cond do
      is_nil(user) ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      demoting_last_manager?(user, role) ->
        {:noreply, put_flash(socket, :error, "Can't demote the last active manager.")}

      true ->
        {:ok, _} = Accounts.set_role(user, String.to_existing_atom(role))
        {:noreply, socket |> put_flash(:info, "Role updated.") |> load_users()}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    user = Accounts.get_user(id)

    cond do
      is_nil(user) ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      deactivating_last_manager?(user) ->
        {:noreply, put_flash(socket, :error, "Can't deactivate the last active manager.")}

      true ->
        {:ok, _} = Accounts.set_active(user, !user.active)
        {:noreply, socket |> put_flash(:info, "Updated.") |> load_users()}
    end
  end

  defp demoting_last_manager?(user, "agent"),
    do: user.role == :manager and user.active and Accounts.manager_count() <= 1

  defp demoting_last_manager?(_user, _role), do: false

  defp deactivating_last_manager?(user),
    do: user.active and user.role == :manager and Accounts.manager_count() <= 1

  defp load_users(socket), do: assign(socket, :users, Accounts.list_users())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:agents}
    >
      <h1 class="text-2xl font-semibold mb-1">People</h1>
      <p class="text-sm text-base-content/60 mb-4">
        People appear here after their first sign-in. Managers see everything; agents see only their own.
      </p>
      <div class="overflow-hidden border border-base-300 rounded-lg">
        <table class="w-full text-sm text-left">
          <thead class="bg-base-200 text-xs uppercase tracking-wider text-base-content/60">
            <tr>
              <th class="px-4 py-3">User</th>
              <th class="px-4 py-3">Email</th>
              <th class="px-4 py-3">Role</th>
              <th class="px-4 py-3">Active</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr :for={u <- @users} class="hover:bg-base-200/50">
              <td class="px-4 py-3 font-medium">{u.username}</td>
              <td class="px-4 py-3">{u.email}</td>
              <td class="px-4 py-3">
                <form id={"role-form-#{u.id}"} phx-change="set_role">
                  <input type="hidden" name="user_id" value={u.id} />
                  <select
                    name="role"
                    class="border border-base-300 rounded px-2 py-1 text-xs bg-base-100"
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
                  class={["text-xs hover:underline", (u.active && "text-error") || "text-primary"]}
                >
                  {if u.active, do: "Deactivate", else: "Activate"}
                </button>
                <span :if={!u.active} class="ml-2 text-xs text-base-content/40">(inactive)</span>
              </td>
            </tr>
            <tr :if={@users == []}>
              <td colspan="4" class="px-4 py-6 text-center text-base-content/40 text-sm">
                No people yet.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.agent_app>
    """
  end
end
