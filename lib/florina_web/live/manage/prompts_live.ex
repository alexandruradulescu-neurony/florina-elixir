defmodule FlorinaWeb.Manage.PromptsLive do
  @moduledoc """
  Manager editor for Voice Prompts — the literal system prompt + greeting Florina
  speaks on PRE/POST calls. At most one active prompt per type; `activate/1`
  flips it. A live preview substitutes dummy values for the template variables.

  Edits set `is_overridden` (in the context) so a central publish won't clobber
  the tenant's local copy. Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.VoicePrompts
  alias Florina.Calls.VoicePrompt

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> load_prompts() |> start_new()}
  end

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, start_new(socket)}

  def handle_event("edit", %{"id" => id}, socket) do
    case VoicePrompts.get(id) do
      nil -> {:noreply, put_flash(socket, :error, "Prompt not found.")}
      p -> {:noreply, socket |> assign(:editing, p) |> assign_form(VoicePrompt.changeset(p, %{}))}
    end
  end

  def handle_event("validate", %{"voice_prompt" => params}, socket) do
    base = socket.assigns.editing || %VoicePrompt{}
    changeset = base |> VoicePrompt.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"voice_prompt" => params}, socket) do
    result =
      case socket.assigns.editing do
        nil -> VoicePrompts.create(params)
        p -> VoicePrompts.update(p, params)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket |> load_prompts() |> start_new() |> put_flash(:info, "Voice prompt saved.")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("activate", %{"id" => id}, socket) do
    case VoicePrompts.get(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Prompt not found.")}

      p ->
        {:ok, _} = VoicePrompts.activate(p)
        {:noreply, socket |> load_prompts() |> put_flash(:info, "Activated.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case VoicePrompts.get(id) do
      nil ->
        {:noreply, socket}

      p ->
        {:ok, _} = VoicePrompts.delete(p)
        {:noreply, socket |> load_prompts() |> start_new() |> put_flash(:info, "Deleted.")}
    end
  end

  defp load_prompts(socket) do
    assign(socket,
      pre_prompts: VoicePrompts.list_by_type(:PRE),
      post_prompts: VoicePrompts.list_by_type(:POST)
    )
  end

  defp start_new(socket) do
    socket |> assign(:editing, nil) |> assign_form(VoicePrompt.changeset(%VoicePrompt{}, %{}))
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:voice_prompts}
    >
      <h1 class="text-2xl font-semibold mb-1">Voice Prompts</h1>
      <p class="text-sm text-base-content/60 mb-6">
        What Florina says on calls. One prompt is active per type (pre / post).
      </p>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div class="space-y-6">
          <.prompt_group title="Pre-call" prompts={@pre_prompts} />
          <.prompt_group title="Post-call" prompts={@post_prompts} />
        </div>

        <div class="rounded-lg border border-base-300 p-4 h-fit">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-medium">
              {(@editing && "Edit prompt") || "New prompt"}
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
            id="voice-prompt-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <.input field={@form[:name]} type="text" label="Name" />
            <.input
              field={@form[:prompt_type]}
              type="select"
              label="Type"
              options={[{"Pre-call", :PRE}, {"Post-call", :POST}]}
            />
            <.input
              field={@form[:system_prompt]}
              type="textarea"
              label="System prompt (what Florina is told to do)"
              rows="6"
              class="font-mono text-xs"
            />
            <.input
              field={@form[:first_message]}
              type="textarea"
              label="First message (greeting)"
              rows="2"
            />
            <.input field={@form[:is_active]} type="checkbox" label="Active (only one per type)" />
            <.button type="submit" variant="primary">{(@editing && "Update") || "Create"}</.button>
          </.form>

          <div class="mt-4 rounded-lg bg-base-200/60 p-3">
            <div class="text-xs font-semibold text-base-content/60 mb-1">Live preview</div>
            <p class="text-sm font-medium whitespace-pre-line">
              {preview(@form[:first_message].value)}
            </p>
            <p class="mt-2 text-xs text-base-content/70 whitespace-pre-line">
              {preview(@form[:system_prompt].value)}
            </p>
          </div>

          <p class="mt-3 text-xs text-base-content/40">
            Variables: <code>{"{agent_name}"}</code>, <code>{"{customer_name}"}</code>, <code>{"{meeting_title}"}</code>.
          </p>
        </div>
      </div>
    </Layouts.agent_app>
    """
  end

  attr :title, :string, required: true
  attr :prompts, :list, required: true

  defp prompt_group(assigns) do
    ~H"""
    <div>
      <h3 class="text-sm font-semibold text-base-content/60 mb-2">{@title}</h3>
      <div class="space-y-2">
        <div
          :for={p <- @prompts}
          class="flex items-center justify-between rounded-lg border border-base-300 px-3 py-2"
        >
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium truncate">{p.name}</span>
              <span
                :if={p.is_active}
                class="rounded-full bg-success/10 text-success px-2 py-0.5 text-xs font-medium"
              >
                active
              </span>
            </div>
            <div class="text-xs text-base-content/50 truncate">{snippet(p.system_prompt)}</div>
          </div>
          <div class="flex gap-3 shrink-0">
            <button
              :if={!p.is_active}
              phx-click="activate"
              phx-value-id={p.id}
              class="text-xs text-primary hover:underline"
            >
              Activate
            </button>
            <button phx-click="edit" phx-value-id={p.id} class="text-xs text-primary hover:underline">
              Edit
            </button>
            <button
              phx-click="delete"
              phx-value-id={p.id}
              data-confirm={"Delete #{p.name}?"}
              class="text-xs text-error hover:underline"
            >
              Delete
            </button>
          </div>
        </div>
        <p :if={@prompts == []} class="text-sm text-base-content/40">None yet.</p>
      </div>
    </div>
    """
  end

  defp preview(nil), do: ""

  defp preview(text) when is_binary(text) do
    text
    |> String.replace("{agent_name}", "John Doe")
    |> String.replace("{customer_name}", "Acme Corporation")
    |> String.replace("{meeting_title}", "Q4 Product Demo")
  end

  defp snippet(text) when is_binary(text) and text != "" do
    if String.length(text) > 80, do: String.slice(text, 0, 80) <> "…", else: text
  end

  defp snippet(_), do: ""
end
