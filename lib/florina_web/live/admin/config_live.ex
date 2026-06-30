defmodule FlorinaWeb.Admin.ConfigLive do
  @moduledoc """
  Operator admin: view and edit canonical central config, publish to all tenants.

  Uses Florina.CentralConfig (control-plane). No tenant resolution.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.Admin.AdminAuth

  alias Florina.CentralConfig

  @impl true
  def mount(_params, _session, socket) do
    domains = Enum.map(Florina.Enums.mega_prompt_domain_values(), fn {_atom, value} -> value end)

    {:ok,
     socket
     |> load_config()
     |> assign(:editing, nil)
     |> assign(:edit_form, nil)
     |> assign(:mega_prompt_domains, domains)}
  end

  # ---------------------------------------------------------------------------
  # Publish all
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("publish_all", _params, socket) do
    task = Task.async(fn -> CentralConfig.publish_all() end)

    socket =
      try do
        case Task.await(task, 30_000) do
          {:ok, %{published: n, failed: []}} ->
            put_flash(socket, :info, "Config published to #{n} tenant(s).")

          {:ok, %{published: n, failed: failed}} ->
            slugs = failed |> Enum.map(& &1.slug) |> Enum.join(", ")
            put_flash(socket, :error, "Published to #{n} tenant(s); failed for: #{slugs}.")

          {:error, reason} ->
            put_flash(socket, :error, "Publish failed: #{inspect(reason)}")
        end
      catch
        :exit, reason ->
          put_flash(socket, :error, "Publish task crashed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Edit mega prompts
  # ---------------------------------------------------------------------------

  def handle_event("edit_mega_prompt", %{"id" => id}, socket) do
    case parse_id(id) do
      nil ->
        {:noreply, socket}

      int ->
        mp = CentralConfig.get_mega_prompt!(int)
        form = to_form(%{"name" => mp.name, "meta_prompt" => mp.meta_prompt}, as: :mega_prompt)
        {:noreply, socket |> assign(:editing, {:mega_prompt, mp}) |> assign(:edit_form, form)}
    end
  end

  def handle_event("save_mega_prompt", %{"mega_prompt" => params}, socket) do
    {:mega_prompt, mp} = socket.assigns.editing

    case CentralConfig.update_mega_prompt(mp, params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Mega prompt updated.")
         |> assign(:editing, nil)
         |> assign(:edit_form, nil)
         |> load_config()}

      {:error, cs} ->
        {:noreply, assign(socket, :edit_form, to_form(cs, as: :mega_prompt))}
    end
  end

  # ---------------------------------------------------------------------------
  # Create a new mega prompt
  # ---------------------------------------------------------------------------

  def handle_event("new_mega_prompt", _params, socket) do
    default_domain = List.first(socket.assigns.mega_prompt_domains)

    form =
      to_form(%{"domain" => default_domain, "name" => "", "meta_prompt" => ""}, as: :mega_prompt)

    {:noreply, socket |> assign(:editing, :new_mega_prompt) |> assign(:edit_form, form)}
  end

  def handle_event("save_new_mega_prompt", %{"mega_prompt" => params}, socket) do
    case CentralConfig.create_and_activate_mega_prompt(params) do
      {:ok, _mp} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Mega prompt created and set active — Publish to push it to tenants."
         )
         |> assign(:editing, nil)
         |> assign(:edit_form, nil)
         |> load_config()}

      {:error, :invalid_domain} ->
        {:noreply, put_flash(socket, :error, "Pick a valid domain.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:edit_form, to_form(params, as: :mega_prompt))
         |> put_flash(:error, "Couldn't create that prompt — name and prompt text are required.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Edit methodologies
  # ---------------------------------------------------------------------------

  def handle_event("edit_methodology", %{"id" => id}, socket) do
    case parse_id(id) do
      nil ->
        {:noreply, socket}

      int ->
        m = CentralConfig.get_methodology!(int)

        form =
          to_form(
            %{
              "name" => m.name,
              "description" => m.description,
              "source_material" => m.source_material
            },
            as: :methodology
          )

        {:noreply, socket |> assign(:editing, {:methodology, m}) |> assign(:edit_form, form)}
    end
  end

  def handle_event("save_methodology", %{"methodology" => params}, socket) do
    {:methodology, m} = socket.assigns.editing

    case CentralConfig.update_methodology(m, params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Methodology updated.")
         |> assign(:editing, nil)
         |> assign(:edit_form, nil)
         |> load_config()}

      {:error, cs} ->
        {:noreply, assign(socket, :edit_form, to_form(cs, as: :methodology))}
    end
  end

  def handle_event("new_methodology", _params, socket) do
    form =
      to_form(%{"name" => "", "description" => "", "source_material" => ""}, as: :methodology)

    {:noreply, socket |> assign(:editing, :new_methodology) |> assign(:edit_form, form)}
  end

  def handle_event("save_new_methodology", %{"methodology" => params}, socket) do
    case CentralConfig.create_methodology(params) do
      {:ok, _m} ->
        {:noreply,
         socket
         |> put_flash(:info, "Methodology created — Publish to push it to tenants.")
         |> assign(:editing, nil)
         |> assign(:edit_form, nil)
         |> load_config()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:edit_form, to_form(params, as: :methodology))
         |> put_flash(:error, "Couldn't create that methodology — a name is required.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Edit scenarios
  # ---------------------------------------------------------------------------

  def handle_event("edit_scenario", %{"id" => id}, socket) do
    case parse_id(id) do
      nil ->
        {:noreply, socket}

      int ->
        s = CentralConfig.get_scenario!(int)
        form = to_form(%{"name" => s.name, "description" => s.description}, as: :scenario)
        {:noreply, socket |> assign(:editing, {:scenario, s}) |> assign(:edit_form, form)}
    end
  end

  def handle_event("save_scenario", %{"scenario" => params}, socket) do
    {:scenario, s} = socket.assigns.editing

    case CentralConfig.update_scenario(s, params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Scenario updated.")
         |> assign(:editing, nil)
         |> assign(:edit_form, nil)
         |> load_config()}

      {:error, cs} ->
        {:noreply, assign(socket, :edit_form, to_form(cs, as: :scenario))}
    end
  end

  def handle_event("new_scenario", _params, socket) do
    form = to_form(%{"name" => "", "slug" => "", "description" => ""}, as: :scenario)
    {:noreply, socket |> assign(:editing, :new_scenario) |> assign(:edit_form, form)}
  end

  def handle_event("save_new_scenario", %{"scenario" => params}, socket) do
    case CentralConfig.create_scenario(ensure_slug(params)) do
      {:ok, _s} ->
        {:noreply,
         socket
         |> put_flash(:info, "Scenario created — Publish to push it to tenants.")
         |> assign(:editing, nil)
         |> assign(:edit_form, nil)
         |> load_config()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:edit_form, to_form(params, as: :scenario))
         |> put_flash(
           :error,
           "Couldn't create that scenario — a name is required and the slug must be unique."
         )}
    end
  end

  def handle_event("delete_scenario", %{"id" => id}, socket) do
    with int when not is_nil(int) <- parse_id(id),
         s when not is_nil(s) <- CentralConfig.get_scenario(int),
         {:ok, _} <- CentralConfig.delete_scenario(s) do
      {:noreply, socket |> put_flash(:info, "Scenario deleted.") |> load_config()}
    else
      _ ->
        {:noreply, socket |> put_flash(:error, "Couldn't delete that scenario.") |> load_config()}
    end
  end

  def handle_event("delete_mega_prompt", %{"id" => id}, socket) do
    with int when not is_nil(int) <- parse_id(id),
         mp when not is_nil(mp) <- CentralConfig.get_mega_prompt(int),
         {:ok, _} <- CentralConfig.delete_mega_prompt(mp) do
      {:noreply, socket |> put_flash(:info, "Mega prompt deleted.") |> load_config()}
    else
      _ ->
        {:noreply,
         socket |> put_flash(:error, "Couldn't delete that mega prompt.") |> load_config()}
    end
  end

  def handle_event("delete_methodology", %{"id" => id}, socket) do
    with int when not is_nil(int) <- parse_id(id),
         m when not is_nil(m) <- CentralConfig.get_methodology(int),
         {:ok, _} <- CentralConfig.delete_methodology(m) do
      {:noreply, socket |> put_flash(:info, "Methodology deleted.") |> load_config()}
    else
      _ ->
        {:noreply,
         socket |> put_flash(:error, "Couldn't delete that methodology.") |> load_config()}
    end
  end

  # ---------------------------------------------------------------------------
  # Edit global settings
  # ---------------------------------------------------------------------------

  def handle_event("edit_settings", _params, socket) do
    s = socket.assigns.settings

    form =
      to_form(
        %{
          "pre_call_offset_minutes" => s.pre_call_offset_minutes,
          "post_call_offset_minutes" => s.post_call_offset_minutes,
          "retry_interval_minutes" => s.retry_interval_minutes,
          "max_call_attempts_per_phase" => s.max_call_attempts_per_phase,
          "max_context_tokens_warn" => s.max_context_tokens_warn
        },
        as: :settings
      )

    {:noreply, socket |> assign(:editing, {:settings, s}) |> assign(:edit_form, form)}
  end

  def handle_event("save_settings", %{"settings" => params}, socket) do
    {:settings, _s} = socket.assigns.editing

    case CentralConfig.update_settings(params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Global settings updated.")
         |> assign(:editing, nil)
         |> assign(:edit_form, nil)
         |> load_config()}

      {:error, cs} ->
        {:noreply, assign(socket, :edit_form, to_form(cs, as: :settings))}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing, nil) |> assign(:edit_form, nil)}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-5xl mx-auto">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-semibold text-gray-900 dark:text-white">Central Config</h1>
            <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
              <a href="/admin" class="hover:underline">Admin</a> &rsaquo; Config
            </p>
          </div>
          <div class="flex gap-2">
            <a
              href="/admin/tenants"
              class="px-3 py-1.5 text-sm font-semibold rounded-md bg-white text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"
            >
              Tenants
            </a>
            <button
              phx-click="publish_all"
              data-confirm="Publish canonical config to ALL active tenants? Rows marked as overridden will be skipped."
              class="px-4 py-1.5 text-sm font-semibold bg-indigo-600 text-white rounded-md shadow-xs hover:bg-indigo-500 dark:bg-indigo-500 dark:hover:bg-indigo-400"
            >
              Publish to all tenants
            </button>
          </div>
        </div>

        <%!-- Edit panel (inline, shown when editing != nil) --%>
        <div
          :if={@editing}
          class="border border-gray-200 rounded-lg p-6 mb-8 bg-gray-50 dark:border-white/10 dark:bg-white/5"
        >
          <%= case @editing do %>
            <% :new_mega_prompt -> %>
              <h2 class="text-base font-medium mb-4 text-gray-900 dark:text-white">
                New mega prompt
              </h2>
              <.form for={@edit_form} phx-submit="save_new_mega_prompt" class="space-y-3">
                <div>
                  <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Domain
                  </label>
                  <select
                    name="mega_prompt[domain]"
                    class="w-full rounded-md bg-white px-3 py-2 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10"
                  >
                    <option
                      :for={d <- @mega_prompt_domains}
                      value={d}
                      selected={@edit_form[:domain].value == d}
                    >
                      {d}
                    </option>
                  </select>
                </div>
                <.text_field label="Name" name="mega_prompt[name]" form={@edit_form} field={:name} />
                <.textarea_field
                  label="Meta prompt"
                  name="mega_prompt[meta_prompt]"
                  form={@edit_form}
                  field={:meta_prompt}
                />
                <.form_buttons />
              </.form>
            <% {:mega_prompt, mp} -> %>
              <h2 class="text-base font-medium mb-4 text-gray-900 dark:text-white">
                Edit mega prompt — {mp.domain}
              </h2>
              <.form for={@edit_form} phx-submit="save_mega_prompt" class="space-y-3">
                <.text_field label="Name" name="mega_prompt[name]" form={@edit_form} field={:name} />
                <.textarea_field
                  label="Meta prompt"
                  name="mega_prompt[meta_prompt]"
                  form={@edit_form}
                  field={:meta_prompt}
                />
                <.form_buttons />
              </.form>
            <% :new_methodology -> %>
              <h2 class="text-base font-medium mb-4 text-gray-900 dark:text-white">
                New methodology
              </h2>
              <.form for={@edit_form} phx-submit="save_new_methodology" class="space-y-3">
                <.text_field
                  label="Name"
                  name="methodology[name]"
                  form={@edit_form}
                  field={:name}
                />
                <.textarea_field
                  label="Description"
                  name="methodology[description]"
                  form={@edit_form}
                  field={:description}
                />
                <.textarea_field
                  label="Source material"
                  name="methodology[source_material]"
                  form={@edit_form}
                  field={:source_material}
                />
                <.form_buttons />
              </.form>
            <% {:methodology, m} -> %>
              <h2 class="text-base font-medium mb-4 text-gray-900 dark:text-white">
                Edit methodology — {m.name}
              </h2>
              <.form for={@edit_form} phx-submit="save_methodology" class="space-y-3">
                <.text_field
                  label="Name"
                  name="methodology[name]"
                  form={@edit_form}
                  field={:name}
                />
                <.textarea_field
                  label="Description"
                  name="methodology[description]"
                  form={@edit_form}
                  field={:description}
                />
                <.textarea_field
                  label="Source material"
                  name="methodology[source_material]"
                  form={@edit_form}
                  field={:source_material}
                />
                <.form_buttons />
              </.form>
            <% :new_scenario -> %>
              <h2 class="text-base font-medium mb-4 text-gray-900 dark:text-white">
                New scenario
              </h2>
              <.form for={@edit_form} phx-submit="save_new_scenario" class="space-y-3">
                <.text_field label="Name" name="scenario[name]" form={@edit_form} field={:name} />
                <.text_field
                  label="Slug (optional — auto-generated from the name)"
                  name="scenario[slug]"
                  form={@edit_form}
                  field={:slug}
                />
                <.textarea_field
                  label="Description"
                  name="scenario[description]"
                  form={@edit_form}
                  field={:description}
                />
                <.form_buttons />
              </.form>
            <% {:scenario, s} -> %>
              <h2 class="text-base font-medium mb-4 text-gray-900 dark:text-white">
                Edit scenario — {s.name}
              </h2>
              <.form for={@edit_form} phx-submit="save_scenario" class="space-y-3">
                <.text_field label="Name" name="scenario[name]" form={@edit_form} field={:name} />
                <.textarea_field
                  label="Description"
                  name="scenario[description]"
                  form={@edit_form}
                  field={:description}
                />
                <.form_buttons />
              </.form>
            <% {:settings, _s} -> %>
              <h2 class="text-base font-medium mb-4 text-gray-900 dark:text-white">
                Edit global settings
              </h2>
              <.form for={@edit_form} phx-submit="save_settings" class="space-y-3">
                <.text_field
                  label="Pre-call offset (min)"
                  name="settings[pre_call_offset_minutes]"
                  form={@edit_form}
                  field={:pre_call_offset_minutes}
                  type="number"
                />
                <.text_field
                  label="Post-call offset (min)"
                  name="settings[post_call_offset_minutes]"
                  form={@edit_form}
                  field={:post_call_offset_minutes}
                  type="number"
                />
                <.text_field
                  label="Retry interval (min)"
                  name="settings[retry_interval_minutes]"
                  form={@edit_form}
                  field={:retry_interval_minutes}
                  type="number"
                />
                <.text_field
                  label="Max call attempts per phase"
                  name="settings[max_call_attempts_per_phase]"
                  form={@edit_form}
                  field={:max_call_attempts_per_phase}
                  type="number"
                />
                <.text_field
                  label="Max context tokens (warn)"
                  name="settings[max_context_tokens_warn]"
                  form={@edit_form}
                  field={:max_context_tokens_warn}
                  type="number"
                />
                <.form_buttons />
              </.form>
          <% end %>
        </div>

        <%!-- Global settings --%>
        <.section_header title="Global settings">
          <button
            phx-click="edit_settings"
            class="text-xs font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
          >Edit</button>
        </.section_header>
        <div class="border border-gray-200 rounded-lg divide-y divide-gray-200 mb-8 text-sm dark:border-white/10 dark:divide-white/10">
          <.kv_row label="Pre-call offset" value={"#{@settings.pre_call_offset_minutes} min"} />
          <.kv_row label="Post-call offset" value={"#{@settings.post_call_offset_minutes} min"} />
          <.kv_row label="Retry interval" value={"#{@settings.retry_interval_minutes} min"} />
          <.kv_row
            label="Max call attempts per phase"
            value={to_string(@settings.max_call_attempts_per_phase)}
          />
          <.kv_row
            label="Max context tokens (warn)"
            value={to_string(@settings.max_context_tokens_warn)}
          />
        </div>

        <%!-- Mega prompts --%>
        <.section_header title={"Mega prompts (#{length(@mega_prompts)})"}>
          <button
            phx-click="new_mega_prompt"
            class="text-xs font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
          >+ New mega prompt</button>
        </.section_header>
        <.config_table rows={@mega_prompts} event="edit_mega_prompt" delete_event="delete_mega_prompt">
          <:col label="Domain"></:col>
          <:col label="Name"></:col>
          <:col label="Active"></:col>
          <:row_render :let={mp}>
            <td class="px-4 py-2 font-mono text-xs">{mp.domain}</td>
            <td class="px-4 py-2">{mp.name}</td>
            <td class="px-4 py-2">{if mp.is_active, do: "yes", else: "no"}</td>
          </:row_render>
        </.config_table>

        <%!-- Methodologies --%>
        <.section_header title={"Methodologies (#{length(@methodologies)})"}>
          <button
            phx-click="new_methodology"
            class="text-xs font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
          >+ New methodology</button>
        </.section_header>
        <.config_table
          rows={@methodologies}
          event="edit_methodology"
          delete_event="delete_methodology"
        >
          <:col label="Name"></:col>
          <:col label="Active"></:col>
          <:row_render :let={m}>
            <td class="px-4 py-2">{m.name}</td>
            <td class="px-4 py-2">{if m.is_active, do: "yes", else: "no"}</td>
          </:row_render>
        </.config_table>

        <%!-- Scenarios --%>
        <.section_header title={"Scenarios (#{length(@scenarios)})"}>
          <button
            phx-click="new_scenario"
            class="text-xs font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
          >+ New scenario</button>
        </.section_header>
        <.config_table rows={@scenarios} event="edit_scenario" delete_event="delete_scenario">
          <:col label="Name"></:col>
          <:col label="Slug"></:col>
          <:col label="Active"></:col>
          <:row_render :let={s}>
            <td class="px-4 py-2">{s.name}</td>
            <td class="px-4 py-2 font-mono text-xs">{s.slug}</td>
            <td class="px-4 py-2">{if s.is_active, do: "yes", else: "no"}</td>
          </:row_render>
        </.config_table>
      </div>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Sub-components
  # ---------------------------------------------------------------------------

  defp section_header(assigns) do
    assigns = assign_new(assigns, :inner_block, fn -> nil end)

    ~H"""
    <div class="flex items-center justify-between mb-2">
      <h2 class="text-base font-semibold text-gray-900 dark:text-white">{@title}</h2>
      <div :if={@inner_block}>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  defp kv_row(assigns) do
    ~H"""
    <div class="flex px-4 py-2 gap-4">
      <span class="text-gray-500 dark:text-gray-400 w-48 shrink-0">{@label}</span>
      <span class="font-mono text-gray-900 dark:text-white">{@value}</span>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :event, :string, required: true
  attr :delete_event, :string, default: nil

  slot :col, required: true do
    attr :label, :string, required: true
  end

  slot :row_render, required: true

  defp config_table(assigns) do
    ~H"""
    <div class="overflow-hidden border border-gray-200 rounded-lg mb-8 dark:border-white/10">
      <table class="w-full text-sm text-left">
        <thead class="bg-gray-50 text-xs uppercase tracking-wider text-gray-500 dark:bg-white/5 dark:text-gray-400">
          <tr>
            <th :for={col <- @col} class="px-4 py-3 font-semibold">{col.label}</th>
            <th class="px-4 py-3 font-semibold">Actions</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-200 dark:divide-white/10 text-gray-700 dark:text-gray-300">
          <tr :for={row <- @rows} class="hover:bg-gray-50 dark:hover:bg-white/5">
            {render_slot(@row_render, row)}
            <td class="px-4 py-2">
              <button
                phx-click={@event}
                phx-value-id={row.id}
                class="text-xs font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
              >
                Edit
              </button>
              <button
                :if={@delete_event}
                phx-click={@delete_event}
                phx-value-id={row.id}
                data-confirm="Delete this entry? Tenants that already have it keep their copy."
                class="ml-3 text-xs font-medium text-red-600 hover:text-red-500 dark:text-red-400"
              >
                Delete
              </button>
            </td>
          </tr>
          <tr :if={@rows == []}>
            <td colspan="10" class="px-4 py-6 text-center text-gray-400 text-sm">
              No entries.
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :form, :any, required: true
  attr :field, :atom, required: true
  attr :type, :string, default: "text"

  defp text_field(assigns) do
    ~H"""
    <div>
      <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">{@label}</label>
      <input
        type={@type}
        name={@name}
        value={@form[@field] && @form[@field].value}
        class="w-full rounded-md bg-white px-3 py-2 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 placeholder:text-gray-400 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500"
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :form, :any, required: true
  attr :field, :atom, required: true

  defp textarea_field(assigns) do
    ~H"""
    <div>
      <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">{@label}</label>
      <textarea
        name={@name}
        rows="5"
        class="w-full rounded-md bg-white px-3 py-2 text-sm font-mono text-gray-900 outline-1 -outline-offset-1 outline-gray-300 placeholder:text-gray-400 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500"
      >{@form[@field] && @form[@field].value}</textarea>
    </div>
    """
  end

  defp form_buttons(assigns) do
    ~H"""
    <div class="flex gap-2 pt-1">
      <button
        type="submit"
        class="px-4 py-2 bg-indigo-600 text-white text-sm font-semibold rounded-md shadow-xs hover:bg-indigo-500 dark:bg-indigo-500 dark:hover:bg-indigo-400"
      >
        Save
      </button>
      <button
        type="button"
        phx-click="cancel_edit"
        class="px-4 py-2 text-sm font-semibold rounded-md bg-white text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 dark:bg-white/10 dark:text-white dark:ring-0 dark:hover:bg-white/20"
      >
        Cancel
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_config(socket) do
    socket
    |> assign(:mega_prompts, CentralConfig.list_mega_prompts())
    |> assign(:methodologies, CentralConfig.list_methodologies())
    |> assign(:scenarios, CentralConfig.list_scenarios())
    |> assign(:settings, CentralConfig.get_settings())
  end

  # Parse an id from a client-sent event param; `nil` on anything non-integer so a
  # tampered event is a no-op rather than a crash.
  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  # Slug is required + unique on a scenario. When the operator leaves it blank,
  # derive a URL-safe slug from the name so they only have to type a name.
  defp ensure_slug(params) do
    case params["slug"] |> to_string() |> String.trim() do
      "" -> Map.put(params, "slug", slugify(params["name"]))
      _ -> params
    end
  end

  defp slugify(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
