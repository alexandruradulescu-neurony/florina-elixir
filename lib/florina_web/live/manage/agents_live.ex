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
    {:ok, socket |> load_users() |> assign_invite_form()}
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
        case Accounts.set_role(user, String.to_existing_atom(role)) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Role updated.") |> load_users()}

          {:error, :last_manager} ->
            {:noreply, put_flash(socket, :error, "Can't demote the last active manager.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not update role.")}
        end
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
        case Accounts.set_active(user, !user.active) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, "Updated.") |> load_users()}

          {:error, :last_manager} ->
            {:noreply, put_flash(socket, :error, "Can't deactivate the last active manager.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not update user.")}
        end
    end
  end

  def handle_event("invite", %{"invite" => params}, socket) do
    case Accounts.invite_agent(params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invited #{user.email}.#{domain_note(socket, user.email)}")
         |> load_users()
         |> assign_invite_form()}

      {:error, :email_required} ->
        {:noreply, put_flash(socket, :error, "Email is required.")}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, "Someone with that email is already here.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, "Couldn't add that person — please check the details.")}
    end
  end

  defp assign_invite_form(socket), do: assign(socket, :invite_form, to_form(%{}, as: :invite))

  # If the invited email's domain isn't allowed for this tenant, they can't sign
  # in yet — surface that inline so the manager isn't surprised.
  defp domain_note(socket, email) do
    domain = email |> String.split("@") |> List.last() |> to_string() |> String.downcase()
    allowed = Enum.map(socket.assigns.tenant.allowed_email_domains || [], &String.downcase/1)

    if domain in allowed,
      do: "",
      else:
        " Note: #{domain} isn't an allowed sign-in domain for this tenant yet — add it in /admin so they can log in."
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
      <h1 class="text-2xl font-semibold mb-1 text-gray-900 dark:text-white">People</h1>
      <p class="text-sm text-gray-500 dark:text-gray-400 mb-4">
        People appear here after their first sign-in. Managers see everything; agents see only their own.
      </p>
      <div class="overflow-hidden border border-gray-200 rounded-lg dark:border-white/10">
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
              <td class="px-4 py-3 text-gray-700 dark:text-gray-300">{u.email}</td>
              <td class="px-4 py-3">
                <form id={"role-form-#{u.id}"} phx-change="set_role">
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
                      "text-indigo-600 dark:text-indigo-400"
                  ]}
                >
                  {if u.active, do: "Deactivate", else: "Activate"}
                </button>
                <span :if={!u.active} class="ml-2 text-xs text-gray-400">(inactive)</span>
              </td>
            </tr>
            <tr :if={@users == []}>
              <td colspan="4" class="px-4 py-6 text-center text-gray-400 text-sm">
                No people yet.
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="mt-8 max-w-2xl rounded-lg border border-gray-200 p-5 dark:border-white/10">
        <h2 class="text-lg font-medium mb-1 text-gray-900 dark:text-white">Add a person</h2>
        <p class="text-sm text-gray-500 dark:text-gray-400 mb-4">
          Pre-create someone by email. They appear here right away; when they first
          sign in with Google or Microsoft their account links up automatically and
          keeps the role you set. Their email domain must be allowed for this tenant.
        </p>
        <.form for={@invite_form} id="invite-form" phx-submit="invite" class="space-y-4">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input field={@invite_form[:email]} type="email" label="Email" required />
            <.input field={@invite_form[:first_name]} type="text" label="First name (optional)" />
            <.input
              field={@invite_form[:role]}
              type="select"
              label="Role"
              options={[{"Agent", "agent"}, {"Manager", "manager"}]}
            />
            <.input field={@invite_form[:phone_number]} type="tel" label="Phone (optional)" />
            <.input
              field={@invite_form[:pipedrive_user_id]}
              type="number"
              label="Pipedrive user ID (optional)"
            />
          </div>
          <.button type="submit" variant="primary">Add person</.button>
        </.form>
      </div>
    </Layouts.agent_app>
    """
  end
end
