defmodule FlorinaWeb.Manage.ClientLive do
  @moduledoc "Manager edit of one client. Managers only."
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.Clients
  alias Florina.Clients.Client

  @status_options [{"New", :new}, {"Existing", :existing}]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Clients.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Client not found.")
         |> push_navigate(to: "/t/#{socket.assigns.tenant.slug}/manage/clients")}

      client ->
        {:ok,
         socket
         |> assign(:client, client)
         |> assign(:status_options, @status_options)
         |> assign_form(Client.changeset(client, %{}))}
    end
  end

  @impl true
  def handle_event("validate", %{"client" => params}, socket) do
    changeset = socket.assigns.client |> Client.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"client" => params}, socket) do
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
          class="text-sm text-base-content/60 hover:underline"
        >
          ← Clients
        </.link>
        <h1 class="text-2xl font-semibold mt-1">{@client.name}</h1>
      </div>

      <.form
        for={@form}
        id="client-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-2xl space-y-5"
      >
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:domain]} type="text" label="Domain" />
        <.input field={@form[:industry]} type="text" label="Industry" />
        <.input field={@form[:status]} type="select" label="Status" options={@status_options} />
        <.input field={@form[:lessons_learned]} type="textarea" label="Lessons learned" rows="4" />
        <.button type="submit" variant="primary">Save changes</.button>
      </.form>
    </Layouts.agent_app>
    """
  end
end
