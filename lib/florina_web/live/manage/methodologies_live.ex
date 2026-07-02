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
        case Methodologies.delete(m) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:methodologies, Methodologies.list())
             |> start_new()
             |> put_flash(:info, "Methodology deleted.")}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:methodologies, Methodologies.list())
             |> put_flash(:error, "Could not delete this methodology.")}
        end
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
      <.header micro="Manage">Methodologies</.header>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div class="space-y-2">
          <div
            :for={m <- @methodologies}
            class="flex items-center justify-between rounded-lg border border-gray-200 bg-white px-4 py-3 dark:border-white/10 dark:bg-white/5"
          >
            <div>
              <div class="text-sm font-bold text-gray-900 dark:text-white">{m.name}</div>
              <div class="text-xs text-gray-500 dark:text-gray-400">
                {(m.is_active && "active") || "inactive"}
              </div>
            </div>
            <div class="flex gap-3">
              <button
                phx-click="edit"
                phx-value-id={m.id}
                class="text-xs font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
              >
                Edit
              </button>
              <button
                phx-click="delete"
                phx-value-id={m.id}
                data-confirm={"Delete #{m.name}?"}
                class="text-xs font-medium text-red-600 hover:text-red-500 dark:text-red-400"
              >
                Delete
              </button>
            </div>
          </div>
          <p :if={@methodologies == []} class="text-sm text-gray-400">
            No methodologies yet.
          </p>
        </div>

        <div class="h-fit rounded-lg border border-gray-200 bg-white p-6 dark:border-white/10 dark:bg-white/5">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-xl font-extrabold tracking-[-0.01em] text-gray-900 dark:text-white">
              {(@editing && "Edit methodology") || "New methodology"}
            </h2>
            <button
              :if={@editing}
              phx-click="new"
              class="text-xs text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
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
