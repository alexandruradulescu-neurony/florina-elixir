defmodule FlorinaWeb.Manage.MeetingLive do
  @moduledoc """
  Manager cockpit for one visit (meeting).

  Left column edits the call prep: manager notes, methodology override, the four
  prompt fields (pre/post prompt + first message) and their lock flags, plus the
  post-call summary, transcripts and AI analysis.

  Right sidebar drives the lifecycle: a status stepper with manual advance,
  "Run AI call" (queues a real pre/post dial through Oban), "Regenerate prompts"
  (re-runs the Auto Prompt Assembler), and the recent generation-run audit trail.

  Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Audit, Methodologies, Prompts, Tenants, Visits}
  alias Florina.Services.VisitPipeline
  alias Florina.Accounts.User
  alias Florina.Visits.Visit
  alias Florina.Workers.DialCall

  @statuses [
    {"PLANNED", "Planned"},
    {"PRE_CALL_DONE", "Pre-call done"},
    {"IN_PROGRESS", "In progress"},
    {"POST_CALL_DONE", "Post-call done"},
    {"COMPLETE", "Complete"}
  ]

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
         |> assign(:runs, Prompts.list_runs_for_visit(visit.id))
         |> assign(:regenerating, nil)
         |> assign_form(Visit.changeset(visit, %{}))}
    end
  end

  # --- form (manager notes, methodology, prompts, locks) ---------------------

  @impl true
  def handle_event("validate", %{"visit" => params}, socket) do
    changeset = socket.assigns.visit |> Visit.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"visit" => params}, socket) do
    case Visits.update(socket.assigns.visit, params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> refresh_visit()
         |> put_flash(:info, "Meeting updated.")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # --- lifecycle: manual status advance --------------------------------------

  def handle_event("advance_status", %{"to" => to}, socket) do
    case Visits.update(socket.assigns.visit, %{status: to}) do
      {:ok, _} ->
        {:noreply, socket |> refresh_visit() |> put_flash(:info, "Status updated.")}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Could not update status.")}
    end
  end

  # --- run a real AI call (queues an Oban dial) ------------------------------

  def handle_event("run_call", %{"phase" => phase}, socket) when phase in ["PRE", "POST"] do
    visit = socket.assigns.visit

    %{
      "visit_id" => visit.id,
      "phase" => phase,
      "tenant_slug" => socket.assigns.tenant.slug,
      # Explicit human request — dial even outside the scheduled call window.
      "manual" => true
    }
    |> DialCall.new()
    |> Oban.insert()

    Audit.log(%{
      action: "manual_call_triggered",
      visit_id: visit.id,
      user_id: socket.assigns.current_agent.id,
      details: %{"phase" => phase}
    })

    {:noreply,
     put_flash(socket, :info, "#{phase_label(phase)} call queued — Florina will dial shortly.")}
  end

  # --- regenerate prompts (re-run the assembler, off the LV process) ---------

  def handle_event("regenerate", %{"phase" => phase}, socket) when phase in ["PRE", "POST"] do
    id = socket.assigns.visit.id
    tenant = socket.assigns.tenant

    socket =
      socket
      |> assign(:regenerating, phase)
      |> start_async(:regenerate, fn ->
        # Re-pin the tenant schema in this Task process before any TenantRepo call.
        Tenants.with_prefix(tenant, fn ->
          visit = Visits.get_with_associations(id)

          result =
            case phase do
              "PRE" -> VisitPipeline.process_pre_call(visit, :MANUAL)
              "POST" -> VisitPipeline.process_post_call(visit, "", :MANUAL)
            end

          {phase, result}
        end)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:regenerate, {:ok, {phase, result}}, socket) do
    socket = socket |> assign(:regenerating, nil) |> refresh_visit()

    case result do
      {:ok, %{run: %{success: true}}} ->
        {:noreply, put_flash(socket, :info, "#{phase_label(phase)} prompts regenerated.")}

      {:ok, %{run: %{success: false} = run}} ->
        {:noreply, put_flash(socket, :error, "Regeneration failed: #{run_error(run)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Regeneration failed: #{inspect(reason)}")}
    end
  end

  def handle_async(:regenerate, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:regenerating, nil)
     |> put_flash(:error, "Regeneration crashed: #{inspect(reason)}")}
  end

  # --- helpers ---------------------------------------------------------------

  defp refresh_visit(socket) do
    visit = Visits.get_with_associations(socket.assigns.visit.id)

    socket
    |> assign(:visit, visit)
    |> assign(:runs, Prompts.list_runs_for_visit(visit.id))
    |> assign_form(Visit.changeset(visit, %{}))
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
          class="text-sm text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
        >
          ← Meetings
        </.link>
        <div class="flex items-center justify-between gap-3 mt-2">
          <h1 class="text-3xl font-extrabold tracking-[-0.01em] text-gray-900 dark:text-white">
            {@visit.title}
          </h1>
          <.link
            navigate={"/t/#{@tenant.slug}/manage/meetings/#{@visit.id}/edit"}
            class="shrink-0 text-sm font-bold text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
          >
            Edit details
          </.link>
        </div>
        <p class="text-sm text-gray-500 dark:text-gray-400">
          {when_label(@visit.start_time)} · {agent_label(@visit.agent)} · {client_label(@visit.client)}
        </p>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Main column --%>
        <div class="lg:col-span-2 space-y-6">
          <div
            :if={@visit.post_call_summary not in [nil, ""]}
            class="rounded-lg border border-gray-200 bg-white p-5 dark:border-white/10 dark:bg-white/5"
          >
            <h2 class="mb-2 text-[11px] font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400">
              Post-call summary
            </h2>
            <p class="text-sm text-gray-600 dark:text-gray-300 whitespace-pre-line">
              {@visit.post_call_summary}
            </p>
          </div>

          <.form
            for={@form}
            id="meeting-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-5"
          >
            <.input
              field={@form[:manager_notes]}
              type="textarea"
              label="Manager notes (visible to the agent)"
              rows="3"
            />

            <.input
              field={@form[:methodology_id]}
              type="select"
              label="Methodology override"
              prompt="No override (use agent / system default)"
              options={Enum.map(@methodologies, &{&1.name, &1.id})}
            />

            <.input
              field={@form[:calls_enabled]}
              type="checkbox"
              label="Florina calls for this meeting (turn off for non-client meetings)"
            />

            <.prompt_field
              form={@form}
              prompt={:pre_call_prompt}
              first={:pre_call_first_message}
              prompt_lock={:pre_call_prompt_locked}
              first_lock={:pre_call_first_message_locked}
              title="Pre-call script"
            />

            <.prompt_field
              form={@form}
              prompt={:post_call_prompt}
              first={:post_call_first_message}
              prompt_lock={:post_call_prompt_locked}
              first_lock={:post_call_first_message_locked}
              title="Post-call script"
            />

            <.button type="submit" variant="primary">Save changes</.button>
          </.form>

          <div
            :if={@visit.call_attempts != []}
            class="rounded-lg border border-gray-200 bg-white p-5 dark:border-white/10 dark:bg-white/5"
          >
            <h2 class="mb-3 text-[11px] font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400">
              Calls & AI analysis
            </h2>
            <div class="space-y-4">
              <div
                :for={call <- Enum.sort_by(@visit.call_attempts, & &1.id, :desc)}
                class="rounded border border-gray-200 p-3 dark:border-white/10"
              >
                <div class="flex items-center gap-2 text-sm">
                  <span class="rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700 dark:bg-white/10 dark:text-gray-200">
                    {call.phase}
                  </span>
                  <span class="text-gray-500 dark:text-gray-400">{call.status}</span>
                </div>
                <div :if={call.summary} class="mt-2 text-sm text-gray-600 dark:text-gray-300">
                  {call.summary}
                </div>
                <details :if={call.transcript not in [nil, ""]} class="mt-2 text-sm">
                  <summary class="cursor-pointer text-gray-500 dark:text-gray-400">
                    Transcript
                  </summary>
                  <p class="mt-1 whitespace-pre-line text-gray-600 dark:text-gray-300">
                    {call.transcript}
                  </p>
                </details>
                <div :if={is_map(call.analysis) and map_size(call.analysis) > 0} class="mt-2">
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                    <div
                      :for={{k, v} <- call.analysis}
                      class="rounded bg-gray-50 p-2 text-xs dark:bg-white/5"
                    >
                      <div class="font-semibold text-gray-900 dark:text-white">{humanize(k)}</div>
                      <div class="text-gray-600 dark:text-gray-300">{format_value(v)}</div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Sidebar --%>
        <div class="space-y-6">
          <div class="rounded-lg border border-gray-200 bg-white p-5 dark:border-white/10 dark:bg-white/5">
            <h2 class="mb-3 text-[11px] font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400">
              Lifecycle
            </h2>
            <ol class="space-y-1">
              <li :for={{value, label} <- statuses()}>
                <button
                  type="button"
                  phx-click="advance_status"
                  phx-value-to={value}
                  disabled={to_string(@visit.status) == value}
                  class={[
                    "w-full text-left rounded px-2 py-1 text-sm",
                    (to_string(@visit.status) == value &&
                       "bg-indigo-50 text-indigo-600 font-semibold dark:bg-indigo-500/10 dark:text-indigo-400") ||
                      "text-gray-600 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-white/5"
                  ]}
                >
                  {label}
                </button>
              </li>
            </ol>
          </div>

          <div class="rounded-lg border border-gray-200 bg-white p-5 dark:border-white/10 dark:bg-white/5">
            <h2 class="mb-1 text-[11px] font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400">
              Run AI call
            </h2>
            <p class="text-xs text-gray-500 dark:text-gray-400 mb-3">
              Queues a real call to the agent's phone.
            </p>
            <div class="flex gap-2">
              <button type="button" phx-click="run_call" phx-value-phase="PRE" class={action_btn()}>
                Pre-call
              </button>
              <button type="button" phx-click="run_call" phx-value-phase="POST" class={action_btn()}>
                Post-call
              </button>
            </div>

            <h2 class="mt-4 mb-1 text-[11px] font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400">
              Regenerate prompts
            </h2>
            <p class="text-xs text-gray-500 dark:text-gray-400 mb-3">
              Re-runs the assembler (skips locked fields).
            </p>
            <div class="flex gap-2">
              <button
                type="button"
                phx-click="regenerate"
                phx-value-phase="PRE"
                disabled={@regenerating != nil}
                class={action_btn()}
              >
                {if @regenerating == "PRE", do: "Working…", else: "Pre-call"}
              </button>
              <button
                type="button"
                phx-click="regenerate"
                phx-value-phase="POST"
                disabled={@regenerating != nil}
                class={action_btn()}
              >
                {if @regenerating == "POST", do: "Working…", else: "Post-call"}
              </button>
            </div>
          </div>

          <div class="rounded-lg border border-gray-200 bg-white p-5 dark:border-white/10 dark:bg-white/5">
            <h2 class="mb-3 text-[11px] font-extrabold uppercase tracking-[0.1em] text-gray-500 dark:text-gray-400">
              Recent generation runs
            </h2>
            <p :if={@runs == []} class="text-sm text-gray-500 dark:text-gray-400">No runs yet.</p>
            <ul :if={@runs != []} class="space-y-2 text-xs">
              <li :for={run <- @runs} class="flex items-center justify-between gap-2">
                <div>
                  <div class="font-medium text-gray-900 dark:text-white">{humanize(run.domain)}</div>
                  <div class="text-gray-500 dark:text-gray-400">
                    {time_label(run.created_at)} · {run.triggered_by}
                  </div>
                </div>
                <div class="text-right">
                  <span class={[
                    "rounded-full px-2 py-0.5 font-medium",
                    (run.success &&
                       "bg-green-100 text-green-700 dark:bg-green-500/10 dark:text-green-400") ||
                      "bg-red-100 text-red-700 dark:bg-red-500/10 dark:text-red-400"
                  ]}>
                    {if run.success, do: "ok", else: "fail"}
                  </span>
                  <div class="text-gray-400 mt-0.5">
                    {run.input_tokens}/{run.output_tokens} tok
                  </div>
                </div>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </Layouts.agent_app>
    """
  end

  # --- function components ----------------------------------------------------

  attr :form, :any, required: true
  attr :prompt, :atom, required: true
  attr :first, :atom, required: true
  attr :prompt_lock, :atom, required: true
  attr :first_lock, :atom, required: true
  attr :title, :string, required: true

  defp prompt_field(assigns) do
    ~H"""
    <fieldset class="rounded-lg border border-gray-200 p-4 space-y-3 dark:border-white/10">
      <legend class="px-1 text-sm font-semibold text-gray-900 dark:text-white">{@title}</legend>
      <.input
        field={@form[@prompt]}
        type="textarea"
        label="Prompt (what Florina is told to do)"
        rows="4"
      />
      <.input
        field={@form[@first]}
        type="textarea"
        label="First message (Florina's opening line)"
        rows="2"
      />
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
        <.input field={@form[@prompt_lock]} type="checkbox" label="Lock prompt" />
        <.input field={@form[@first_lock]} type="checkbox" label="Lock first message" />
      </div>
      <p class="text-xs text-gray-500 dark:text-gray-400">
        When locked, neither the agent nor a regenerate can change that field.
      </p>
    </fieldset>
    """
  end

  # Shared secondary (white) button class for the sidebar actions.
  defp action_btn,
    do:
      "flex-1 inline-flex items-center justify-center rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 shadow-xs ring-1 ring-inset ring-gray-300 hover:bg-gray-50 disabled:opacity-50 cursor-pointer dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"

  # --- view helpers -----------------------------------------------------------

  defp statuses, do: @statuses

  defp run_error(%{error: e}) when is_binary(e) and e != "", do: e
  defp run_error(_), do: "see generation run for details"

  defp phase_label("PRE"), do: "Pre-call"
  defp phase_label("POST"), do: "Post-call"

  defp when_label(%DateTime{} = dt), do: Florina.Tz.format(dt, :datetime)
  defp when_label(_), do: "—"

  defp time_label(%DateTime{} = dt), do: Florina.Tz.format(dt, :short)
  defp time_label(_), do: "—"

  defp agent_label(agent), do: User.display_name(agent) || "—"
  defp client_label(%{name: n}) when is_binary(n), do: n
  defp client_label(_), do: "—"

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace(["_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp format_value(v) when is_list(v), do: Enum.map_join(v, ", ", &format_value/1)
  defp format_value(v), do: inspect(v)
end
