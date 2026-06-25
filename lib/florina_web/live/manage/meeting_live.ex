defmodule FlorinaWeb.Manage.MeetingLive do
  @moduledoc """
  Manager edit of one meeting: leave notes for the agent, lock the AI call prep
  (so the agent can't change it), and override the methodology. Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Methodologies, Visits}
  alias Florina.Visits.Visit

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Visits.get_with_associations(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Meeting not found.")
         |> push_navigate(to: "/t/#{socket.assigns.tenant.slug}/manage/meetings")}

      visit ->
        {:ok,
         socket
         |> assign(:visit, visit)
         |> assign(:methodologies, Methodologies.list_active())
         |> assign_form(Visit.changeset(visit, %{}))}
    end
  end

  @impl true
  def handle_event("validate", %{"visit" => params}, socket) do
    changeset = socket.assigns.visit |> Visit.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"visit" => params}, socket) do
    case Visits.update(socket.assigns.visit, params) do
      {:ok, _updated} ->
        visit = Visits.get_with_associations(socket.assigns.visit.id)

        {:noreply,
         socket
         |> assign(:visit, visit)
         |> assign_form(Visit.changeset(visit, %{}))
         |> put_flash(:info, "Meeting updated.")}

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
      active={:meetings}
    >
      <div class="mb-6">
        <.link
          navigate={"/t/#{@tenant.slug}/manage/meetings"}
          class="text-sm text-base-content/60 hover:underline"
        >
          ← Meetings
        </.link>
        <h1 class="text-2xl font-semibold mt-1">{@visit.title}</h1>
        <p class="text-sm text-base-content/60">
          {when_label(@visit.start_time)} · {agent_label(@visit.agent)} · {client_label(@visit.client)} ·
          <span class="rounded bg-base-200 px-2 py-0.5">{to_string(@visit.status)}</span>
        </p>
      </div>

      <div
        :if={@visit.post_call_summary not in [nil, ""]}
        class="mb-6 rounded-lg border border-base-300 bg-base-100 p-4"
      >
        <h2 class="text-sm font-semibold mb-1">Post-call summary</h2>
        <p class="text-sm text-base-content/70 whitespace-pre-line">{@visit.post_call_summary}</p>
      </div>

      <.form
        for={@form}
        id="meeting-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-2xl space-y-5"
      >
        <.input
          field={@form[:manager_notes]}
          type="textarea"
          label="Manager notes (visible to the agent)"
          rows="4"
        />

        <.input
          field={@form[:methodology_id]}
          type="select"
          label="Methodology override"
          prompt="No override (use agent / system default)"
          options={Enum.map(@methodologies, &{&1.name, &1.id})}
        />

        <fieldset class="rounded-lg border border-base-300 p-4">
          <legend class="px-1 text-sm font-semibold">Lock the AI call prep</legend>
          <p class="text-xs text-base-content/50 mb-3">
            When locked, the agent can't change that part of Florina's call script.
          </p>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
            <.input field={@form[:pre_call_prompt_locked]} type="checkbox" label="Pre-call prompt" />
            <.input
              field={@form[:pre_call_first_message_locked]}
              type="checkbox"
              label="Pre-call first message"
            />
            <.input
              field={@form[:post_call_prompt_locked]}
              type="checkbox"
              label="Post-call prompt"
            />
            <.input
              field={@form[:post_call_first_message_locked]}
              type="checkbox"
              label="Post-call first message"
            />
          </div>
        </fieldset>

        <.button type="submit" variant="primary">Save changes</.button>
      </.form>
    </Layouts.agent_app>
    """
  end

  defp when_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %Y · %H:%M")

  defp agent_label(%{first_name: f, last_name: l, email: e}), do: name_of(f, l, e)
  defp agent_label(_), do: "—"
  defp client_label(%{name: n}) when is_binary(n), do: n
  defp client_label(_), do: "—"

  defp name_of(f, l, e) do
    case [f, l] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> e || "—"
      n -> n
    end
  end
end
