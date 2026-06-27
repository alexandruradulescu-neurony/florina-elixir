defmodule FlorinaWeb.Manage.SettingsLive do
  @moduledoc """
  Manager editor for the per-tenant `GlobalSettings` singleton — call-timing
  offsets, retry interval, token-warning threshold, and the system-wide default
  methodology. Edits set `is_overridden` (in the context). Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Methodologies, Settings}
  alias Florina.Settings.GlobalSettings

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get()

    {:ok,
     socket
     |> assign(:methodologies, Methodologies.list_active())
     |> assign(:settings, settings)
     |> assign_form(GlobalSettings.changeset(settings, %{}))}
  end

  @impl true
  def handle_event("validate", %{"global_settings" => params}, socket) do
    changeset =
      socket.assigns.settings |> GlobalSettings.changeset(params) |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"global_settings" => params}, socket) do
    case Settings.update(params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:settings, settings)
         |> assign_form(GlobalSettings.changeset(settings, %{}))
         |> put_flash(:info, "Settings saved.")}

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
      active={:settings}
    >
      <h1 class="text-2xl font-semibold mb-1">Settings</h1>
      <p class="text-sm text-base-content/60 mb-6">
        System-wide call timing and defaults for this workspace.
      </p>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <.form
          for={@form}
          id="settings-form"
          phx-change="validate"
          phx-submit="save"
          class="lg:col-span-2 max-w-xl space-y-5"
        >
          <.input
            field={@form[:pre_call_offset_minutes]}
            type="number"
            label="Pre-call offset (minutes)"
          />
          <.input
            field={@form[:post_call_offset_minutes]}
            type="number"
            label="Post-call offset (minutes)"
          />
          <.input
            field={@form[:retry_interval_minutes]}
            type="number"
            label="Retry interval (minutes)"
          />
          <.input
            field={@form[:max_context_tokens_warn]}
            type="number"
            label="Token-warning threshold"
          />
          <.input
            field={@form[:default_methodology_id]}
            type="select"
            label="Default methodology"
            prompt="None"
            options={Enum.map(@methodologies, &{&1.name, &1.id})}
          />
          <.button type="submit" variant="primary">Save settings</.button>
        </.form>

        <aside class="text-sm text-base-content/60 space-y-3">
          <p>
            <span class="font-medium text-base-content">Pre / post offset</span>
            — when Florina dials relative to the meeting (negative = before).
          </p>
          <p>
            <span class="font-medium text-base-content">Retry interval</span>
            — wait between dial attempts.
          </p>
          <p>
            <span class="font-medium text-base-content">Token-warning threshold</span>
            — flags a generation run whose context exceeds this.
          </p>
          <p>
            <span class="font-medium text-base-content">Default methodology</span>
            — fallback when no agent or visit override is set.
          </p>
        </aside>
      </div>
    </Layouts.agent_app>
    """
  end
end
