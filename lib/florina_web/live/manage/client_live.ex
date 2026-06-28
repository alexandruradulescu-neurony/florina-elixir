defmodule FlorinaWeb.Manage.ClientLive do
  @moduledoc """
  Manager create / edit / delete of a client. Managers only.

  Delete is blocked while the client still has meetings: the `visit → client` FK
  is `on_delete: :delete_all`, so deleting a client with meetings would silently
  wipe its meeting + call history. Only orphan clients (no meetings) can be
  deleted here.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Clients, Visits}
  alias Florina.Clients.Client

  @status_options [{"New", :new}, {"Existing", :existing}]

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, :status_options, @status_options)

    case socket.assigns.live_action do
      :new ->
        {:ok,
         socket |> assign(:client, %Client{}) |> assign_form(Client.changeset(%Client{}, %{}))}

      :edit ->
        case Clients.get(params["id"]) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, "Client not found.")
             |> push_navigate(to: clients_path(socket))}

          client ->
            {:ok, socket |> assign(:client, client) |> assign_form(Client.changeset(client, %{}))}
        end
    end
  end

  @impl true
  def handle_event("validate", %{"client" => params}, socket) do
    changeset = socket.assigns.client |> Client.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"client" => params}, socket) do
    case socket.assigns.live_action do
      :new -> create(socket, params)
      :edit -> update(socket, params)
    end
  end

  def handle_event("delete", _params, socket) do
    client = socket.assigns.client

    if Visits.list_for_client(client.id) == [] do
      case Clients.delete(client) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Client deleted.")
           |> push_navigate(to: clients_path(socket))}

        {:error, _changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "This client still has history (calls or generation runs) — can't delete it."
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error, "This client has meetings — delete or reassign those first.")}
    end
  end

  defp create(socket, params) do
    case Clients.create(params) do
      {:ok, client} ->
        {:noreply,
         socket
         |> put_flash(:info, "Client created.")
         |> push_navigate(to: "#{clients_path(socket)}/#{client.id}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp update(socket, params) do
    case Clients.update(socket.assigns.client, params) do
      {:ok, client} ->
        {:noreply,
         socket
         |> assign(:client, client)
         |> assign_form(Client.changeset(client, %{}))
         |> put_flash(:info, "Client updated.")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))
  defp clients_path(socket), do: "/t/#{socket.assigns.tenant.slug}/manage/clients"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:clients}
    >
      <div class="mb-6">
        <.link
          navigate={"/t/#{@tenant.slug}/manage/clients"}
          class="text-sm text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
        >
          ← Clients
        </.link>
        <h1 class="text-2xl font-semibold mt-1 text-gray-900 dark:text-white">
          {if @live_action == :new, do: "New client", else: @client.name}
        </h1>
      </div>

      <.form
        for={@form}
        id="client-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-2xl space-y-5"
      >
        <.input field={@form[:name]} type="text" label="Name" required />
        <.input
          :if={@live_action == :new}
          field={@form[:crm_id]}
          type="text"
          label="CRM ID"
          required
        />
        <.input field={@form[:domain]} type="text" label="Domain" />
        <.input field={@form[:industry]} type="text" label="Industry" />
        <.input field={@form[:status]} type="select" label="Status" options={@status_options} />
        <.input field={@form[:ai_summary]} type="textarea" label="AI summary" rows="3" />
        <.input field={@form[:lessons_learned]} type="textarea" label="Lessons learned" rows="4" />
        <.button type="submit" variant="primary">
          {if @live_action == :new, do: "Create client", else: "Save changes"}
        </.button>
      </.form>

      <div
        :if={@live_action == :edit}
        class="max-w-2xl mt-10 rounded-lg border border-red-300 p-5 dark:border-red-500/30"
      >
        <h2 class="text-sm font-semibold text-red-600 dark:text-red-400 mb-1">Danger zone</h2>
        <p class="text-xs text-gray-500 dark:text-gray-400 mb-3">
          Deleting a client is permanent. It's blocked while the client still has meetings.
        </p>
        <button
          phx-click="delete"
          data-confirm={"Delete #{@client.name}? This can't be undone."}
          class="text-sm font-medium text-red-600 hover:text-red-500 dark:text-red-400"
        >
          Delete client
        </button>
      </div>
    </Layouts.agent_app>
    """
  end
end
