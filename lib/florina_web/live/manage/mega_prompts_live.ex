defmodule FlorinaWeb.Manage.MegaPromptsLive do
  @moduledoc """
  Manager editor for Mega Prompts — the versioned meta-prompts that tell Claude
  how to assemble each visit's voice prompt. Grouped by domain (pre-call,
  post-call, lessons-distill).

  Saving ALWAYS creates a new (inactive) version — never edits in place. Old
  versions are kept; "Activate" flips which version is live for its domain.
  Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.Prompts
  alias Florina.Prompts.MegaPrompt

  @domains [
    {:PRE_CALL, "Pre-call"},
    {:POST_CALL, "Post-call"},
    {:LESSONS_DISTILL, "Lessons distill"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> load_domains() |> start_form(:PRE_CALL)}
  end

  @impl true
  def handle_event("new", %{"domain" => domain}, socket) do
    {:noreply, start_form(socket, to_domain(domain))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Prompts.get_mega(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Mega prompt not found.")}

      mp ->
        {:noreply,
         socket
         |> assign(:editing, mp)
         |> assign(:form_domain, mp.domain)
         |> assign_form(%{domain: mp.domain, name: mp.name, meta_prompt: mp.meta_prompt})}
    end
  end

  def handle_event("validate", %{"mega_prompt" => params}, socket) do
    attrs = Map.put(params, "domain", socket.assigns.form_domain)
    changeset = %MegaPrompt{} |> MegaPrompt.changeset(attrs) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"mega_prompt" => params}, socket) do
    attrs = %{
      domain: socket.assigns.form_domain,
      name: params["name"],
      meta_prompt: params["meta_prompt"],
      created_by_id: socket.assigns.current_agent.id
    }

    case Prompts.create_version(attrs) do
      {:ok, mp} ->
        {:noreply,
         socket
         |> load_domains()
         |> start_form(socket.assigns.form_domain)
         |> put_flash(:info, "Saved as v#{mp.version} (inactive). Activate it to go live.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("activate", %{"id" => id}, socket) do
    case Prompts.get_mega(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Mega prompt not found.")}

      mp ->
        {:ok, _} = Prompts.activate(mp)
        {:noreply, socket |> load_domains() |> put_flash(:info, "Activated v#{mp.version}.")}
    end
  end

  defp load_domains(socket) do
    groups =
      Enum.map(@domains, fn {value, label} ->
        %{value: value, label: label, versions: Prompts.list_by_domain(value)}
      end)

    assign(socket, :groups, groups)
  end

  defp start_form(socket, domain) do
    socket
    |> assign(:editing, nil)
    |> assign(:form_domain, domain)
    |> assign_form(%{domain: domain, name: "", meta_prompt: ""})
  end

  defp assign_form(socket, attrs) do
    changeset = MegaPrompt.changeset(%MegaPrompt{}, attrs)
    assign(socket, :form, to_form(changeset))
  end

  defp to_domain(str), do: String.to_existing_atom(str)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:mega_prompts}
    >
      <h1 class="text-2xl font-semibold mb-1">Mega Prompts</h1>
      <p class="text-sm text-base-content/60 mb-6">
        The instructions that tell Claude how to write each call's script. Editing
        always creates a new version; activating one makes it live for its domain.
      </p>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div class="space-y-6">
          <div :for={g <- @groups} class="rounded-lg border border-base-300 p-4">
            <div class="flex items-center justify-between mb-2">
              <h2 class="text-sm font-semibold">{g.label}</h2>
              <button
                phx-click="new"
                phx-value-domain={g.value}
                class="text-xs text-primary hover:underline"
              >
                + New version
              </button>
            </div>
            <table :if={g.versions != []} class="w-full text-left text-xs">
              <thead class="text-base-content/50">
                <tr>
                  <th class="py-1 pr-2 font-medium">Ver</th>
                  <th class="py-1 pr-2 font-medium">Name</th>
                  <th class="py-1 pr-2 font-medium">Status</th>
                  <th class="py-1 pr-2 font-medium">Updated</th>
                  <th class="py-1 font-medium text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={mp <- g.versions} class="border-t border-base-200">
                  <td class="py-1.5 pr-2">v{mp.version}</td>
                  <td class="py-1.5 pr-2">{mp.name}</td>
                  <td class="py-1.5 pr-2">
                    <span
                      :if={mp.is_active}
                      class="rounded-full bg-success/10 text-success px-2 py-0.5 font-medium"
                    >
                      active
                    </span>
                    <span :if={!mp.is_active} class="text-base-content/40">inactive</span>
                  </td>
                  <td class="py-1.5 pr-2 text-base-content/50">{time_label(mp.updated_at)}</td>
                  <td class="py-1.5 text-right space-x-2">
                    <button phx-click="edit" phx-value-id={mp.id} class="text-primary hover:underline">
                      Edit
                    </button>
                    <button
                      :if={!mp.is_active}
                      phx-click="activate"
                      phx-value-id={mp.id}
                      class="text-primary hover:underline"
                    >
                      Activate
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
            <p :if={g.versions == []} class="text-xs text-base-content/40">No versions yet.</p>
          </div>
        </div>

        <div class="rounded-lg border border-base-300 p-4 h-fit">
          <div class="flex items-center justify-between mb-1">
            <h2 class="text-lg font-medium">
              {(@editing && "New version (from v#{@editing.version})") || "New version"}
            </h2>
            <span class="rounded bg-base-200 px-2 py-0.5 text-xs font-medium">
              {domain_label(@form_domain)}
            </span>
          </div>
          <p class="text-xs text-base-content/50 mb-3">
            Saving always creates a new, inactive version — activate it from the list.
          </p>

          <.form
            for={@form}
            id="mega-prompt-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <.input field={@form[:name]} type="text" label="Name" />
            <.input
              field={@form[:meta_prompt]}
              type="textarea"
              label="Meta prompt (instructions to Claude)"
              rows="16"
              class="font-mono text-xs"
            />
            <.button type="submit" variant="primary">Save as new version</.button>
          </.form>

          <p class="mt-3 text-xs text-base-content/40">
            Supports <code>{"{placeholders}"}</code>
            like <code>{"{client_name}"}</code>, <code>{"{methodology_summary}"}</code>, <code>{"{manager_notes}"}</code>.
          </p>
        </div>
      </div>
    </Layouts.agent_app>
    """
  end

  defp domain_label(domain) do
    Enum.find_value(@domains, to_string(domain), fn {v, l} -> v == domain && l end)
  end

  defp time_label(%DateTime{} = dt), do: Calendar.strftime(Florina.Tz.local(dt), "%d %b %Y")
  defp time_label(_), do: "—"
end
