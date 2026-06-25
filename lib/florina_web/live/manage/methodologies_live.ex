defmodule FlorinaWeb.Manage.MethodologiesLive do
  @moduledoc """
  Manager editor for sales methodologies (SPIN, MEDDIC, …): list on the left,
  create/edit form on the right. Edits set `is_overridden` so a central publish
  won't clobber the tenant's local copy (handled in the Methodologies context).
  Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.Methodologies
  alias Florina.Methodologies.Methodology

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:methodologies, Methodologies.list()) |> start_new()}
  end

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, start_new(socket)}

  def handle_event("edit", %{"id" => id}, socket) do
    case Methodologies.get(id) do
      nil -> {:noreply, put_flash(socket, :error, "Methodology not found.")}
      m -> {:noreply, socket |> assign(:editing, m) |> assign_form(Methodology.changeset(m, %{}))}
    end
  end

  def handle_event("validate", %{"methodology" => params}, socket) do
    base = socket.assigns.editing || %Methodology{}
    changeset = base |> Methodology.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"methodology" => params}, socket) do
    result =
      case socket.assigns.editing do
        nil -> Methodologies.create(params)
        m -> Methodologies.update(m, params)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:methodologies, Methodologies.list())
         |> start_new()
         |> put_flash(:info, "Methodology saved.")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Methodologies.get(id) do
      nil ->
        {:noreply, socket}

      m ->
        {:ok, _} = Methodologies.delete(m)

        {:noreply,
         socket
         |> assign(:methodologies, Methodologies.list())
         |> start_new()
         |> put_flash(:info, "Methodology deleted.")}
    end
  end

  defp start_new(socket) do
    socket |> assign(:editing, nil) |> assign_form(Methodology.changeset(%Methodology{}, %{}))
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:methodologies}
    >
      <h1 class="text-2xl font-semibold mb-4">Methodologies</h1>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div class="space-y-2">
          <div
            :for={m <- @methodologies}
            class="flex items-center justify-between rounded-lg border border-base-300 px-3 py-2"
          >
            <div>
              <div class="text-sm font-medium">{m.name}</div>
              <div class="text-xs text-base-content/60">
                {(m.is_active && "active") || "inactive"}
              </div>
            </div>
            <div class="flex gap-3">
              <button
                phx-click="edit"
                phx-value-id={m.id}
                class="text-xs text-primary hover:underline"
              >
                Edit
              </button>
              <button
                phx-click="delete"
                phx-value-id={m.id}
                data-confirm={"Delete #{m.name}?"}
                class="text-xs text-error hover:underline"
              >
                Delete
              </button>
            </div>
          </div>
          <p :if={@methodologies == []} class="text-sm text-base-content/40">
            No methodologies yet.
          </p>
        </div>

        <div class="rounded-lg border border-base-300 p-4 h-fit">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-medium">
              {(@editing && "Edit methodology") || "New methodology"}
            </h2>
            <button
              :if={@editing}
              phx-click="new"
              class="text-xs text-base-content/60 hover:underline"
            >
              + New
            </button>
          </div>
          <.form
            for={@form}
            id="methodology-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <.input field={@form[:name]} type="text" label="Name" />
            <.input field={@form[:description]} type="textarea" label="Description" rows="3" />
            <.input field={@form[:source_material]} type="textarea" label="Source material" rows="3" />
            <.input field={@form[:is_active]} type="checkbox" label="Active" />
            <.button type="submit" variant="primary">{(@editing && "Update") || "Create"}</.button>
          </.form>
        </div>
      </div>
    </Layouts.agent_app>
    """
  end
end
