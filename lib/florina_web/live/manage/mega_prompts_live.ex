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
  def handle_event("new", %{"domain" => domain}, socket)
      when domain in ["PRE_CALL", "POST_CALL", "LESSONS_DISTILL"] do
    {:noreply, start_form(socket, to_domain(domain))}
  end

  def handle_event("new", _params, socket), do: {:noreply, socket}

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
      <h1 class="text-2xl font-semibold mb-1 text-gray-900 dark:text-white">Mega Prompts</h1>
      <p class="text-sm text-gray-500 dark:text-gray-400 mb-6">
        The instructions that tell Claude how to write each call's script. Editing
        always creates a new version; activating one makes it live for its domain.
      </p>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div class="space-y-6">
          <div :for={g <- @groups} class="rounded-lg border border-gray-200 p-4 dark:border-white/10">
            <div class="flex items-center justify-between mb-2">
              <h2 class="text-sm font-semibold text-gray-900 dark:text-white">{g.label}</h2>
              <button
                phx-click="new"
                phx-value-domain={g.value}
                class="text-xs font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
              >
                + New version
              </button>
            </div>
            <table :if={g.versions != []} class="w-full text-left text-xs">
              <thead class="text-gray-500 dark:text-gray-400">
                <tr>
                  <th class="py-1 pr-2 font-medium">Ver</th>
                  <th class="py-1 pr-2 font-medium">Name</th>
                  <th class="py-1 pr-2 font-medium">Status</th>
                  <th class="py-1 pr-2 font-medium">Updated</th>
                  <th class="py-1 font-medium text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={mp <- g.versions} class="border-t border-gray-200 dark:border-white/10">
                  <td class="py-1.5 pr-2 text-gray-700 dark:text-gray-300">v{mp.version}</td>
                  <td class="py-1.5 pr-2 text-gray-700 dark:text-gray-300">{mp.name}</td>
                  <td class="py-1.5 pr-2">
                    <span
                      :if={mp.is_active}
                      class="rounded-full bg-green-100 text-green-700 px-2 py-0.5 font-medium dark:bg-green-500/10 dark:text-green-400"
                    >
                      active
                    </span>
                    <span :if={!mp.is_active} class="text-gray-400">inactive</span>
                  </td>
                  <td class="py-1.5 pr-2 text-gray-500 dark:text-gray-400">
                    {time_label(mp.updated_at)}
                  </td>
                  <td class="py-1.5 text-right space-x-2">
                    <button
                      phx-click="edit"
                      phx-value-id={mp.id}
                      class="font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
                    >
                      Edit
                    </button>
                    <button
                      :if={!mp.is_active}
                      phx-click="activate"
                      phx-value-id={mp.id}
                      class="font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
                    >
                      Activate
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
            <p :if={g.versions == []} class="text-xs text-gray-400">No versions yet.</p>
          </div>
        </div>

        <div class="rounded-lg border border-gray-200 p-4 h-fit dark:border-white/10">
          <div class="flex items-center justify-between mb-1">
            <h2 class="text-lg font-medium text-gray-900 dark:text-white">
              {(@editing && "New version (from v#{@editing.version})") || "New version"}
            </h2>
            <span class="rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700 dark:bg-white/10 dark:text-gray-200">
              {domain_label(@form_domain)}
            </span>
          </div>
          <p class="text-xs text-gray-500 dark:text-gray-400 mb-3">
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

          <p class="mt-3 text-xs text-gray-400">
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
