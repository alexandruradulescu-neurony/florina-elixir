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
    {:ok,
     socket
     |> load_config()
     |> assign(:editing, nil)
     |> assign(:edit_form, nil)}
  end

  # ---------------------------------------------------------------------------
  # Publish all
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("publish_all", _params, socket) do
    task = Task.async(fn -> CentralConfig.publish_all() end)

    case Task.await(task, 30_000) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Config published to all active tenants.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Publish failed: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Edit mega prompts
  # ---------------------------------------------------------------------------

  def handle_event("edit_mega_prompt", %{"id" => id}, socket) do
    mp = CentralConfig.get_mega_prompt!(String.to_integer(id))
    form = to_form(%{"name" => mp.name, "meta_prompt" => mp.meta_prompt}, as: :mega_prompt)
    {:noreply, socket |> assign(:editing, {:mega_prompt, mp}) |> assign(:edit_form, form)}
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
  # Edit voice prompts
  # ---------------------------------------------------------------------------

  def handle_event("edit_voice_prompt", %{"id" => id}, socket) do
    vp = CentralConfig.get_voice_prompt!(String.to_integer(id))

    form =
      to_form(
        %{
          "name" => vp.name,
          "system_prompt" => vp.system_prompt,
          "first_message" => vp.first_message
        },
        as: :voice_prompt
      )

    {:noreply, socket |> assign(:editing, {:voice_prompt, vp}) |> assign(:edit_form, form)}
  end

  def handle_event("save_voice_prompt", %{"voice_prompt" => params}, socket) do
    {:voice_prompt, vp} = socket.assigns.editing

    case CentralConfig.update_voice_prompt(vp, params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Voice prompt updated.")
         |> assign(:editing, nil)
         |> assign(:edit_form, nil)
         |> load_config()}

      {:error, cs} ->
        {:noreply, assign(socket, :edit_form, to_form(cs, as: :voice_prompt))}
    end
  end

  # ---------------------------------------------------------------------------
  # Edit methodologies
  # ---------------------------------------------------------------------------

  def handle_event("edit_methodology", %{"id" => id}, socket) do
    m = CentralConfig.get_methodology!(String.to_integer(id))

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

  # ---------------------------------------------------------------------------
  # Edit scenarios
  # ---------------------------------------------------------------------------

  def handle_event("edit_scenario", %{"id" => id}, socket) do
    s = CentralConfig.get_scenario!(String.to_integer(id))
    form = to_form(%{"name" => s.name, "description" => s.description}, as: :scenario)
    {:noreply, socket |> assign(:editing, {:scenario, s}) |> assign(:edit_form, form)}
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
    <div class="px-4 py-8 max-w-5xl mx-auto">
      <Layouts.flash_group flash={@flash} />
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-semibold">Central Config</h1>
          <p class="text-sm text-gray-500 mt-1">
            <a href="/admin" class="hover:underline">Admin</a> &rsaquo; Config
          </p>
        </div>
        <div class="flex gap-2">
          <a href="/admin/tenants" class="px-3 py-1.5 text-sm border rounded hover:bg-gray-50">
            Tenants
          </a>
          <button
            phx-click="publish_all"
            data-confirm="Publish canonical config to ALL active tenants? Rows marked as overridden will be skipped."
            class="px-4 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
          >
            Publish to all tenants
          </button>
        </div>
      </div>

      <%!-- Edit panel (inline, shown when editing != nil) --%>
      <div :if={@editing} class="border rounded-lg p-6 mb-8 bg-gray-50">
        <%= case @editing do %>
          <% {:mega_prompt, mp} -> %>
            <h2 class="text-base font-medium mb-4">Edit mega prompt — {mp.domain}</h2>
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
          <% {:voice_prompt, vp} -> %>
            <h2 class="text-base font-medium mb-4">Edit voice prompt — {vp.prompt_type}</h2>
            <.form for={@edit_form} phx-submit="save_voice_prompt" class="space-y-3">
              <.text_field label="Name" name="voice_prompt[name]" form={@edit_form} field={:name} />
              <.textarea_field
                label="System prompt"
                name="voice_prompt[system_prompt]"
                form={@edit_form}
                field={:system_prompt}
              />
              <.textarea_field
                label="First message"
                name="voice_prompt[first_message]"
                form={@edit_form}
                field={:first_message}
              />
              <.form_buttons />
            </.form>
          <% {:methodology, m} -> %>
            <h2 class="text-base font-medium mb-4">Edit methodology — {m.name}</h2>
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
          <% {:scenario, s} -> %>
            <h2 class="text-base font-medium mb-4">Edit scenario — {s.name}</h2>
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
            <h2 class="text-base font-medium mb-4">Edit global settings</h2>
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
        <button phx-click="edit_settings" class="text-xs text-blue-600 hover:underline">Edit</button>
      </.section_header>
      <div class="border rounded-lg divide-y mb-8 text-sm">
        <.kv_row label="Pre-call offset" value={"#{@settings.pre_call_offset_minutes} min"} />
        <.kv_row label="Post-call offset" value={"#{@settings.post_call_offset_minutes} min"} />
        <.kv_row label="Retry interval" value={"#{@settings.retry_interval_minutes} min"} />
        <.kv_row
          label="Max context tokens (warn)"
          value={to_string(@settings.max_context_tokens_warn)}
        />
      </div>

      <%!-- Mega prompts --%>
      <.section_header title={"Mega prompts (#{length(@mega_prompts)})"} />
      <.config_table rows={@mega_prompts} event="edit_mega_prompt">
        <:col label="Domain"></:col>
        <:col label="Name"></:col>
        <:col label="Active"></:col>
        <:row_render :let={mp}>
          <td class="px-4 py-2 font-mono text-xs">{mp.domain}</td>
          <td class="px-4 py-2">{mp.name}</td>
          <td class="px-4 py-2">{if mp.is_active, do: "yes", else: "no"}</td>
        </:row_render>
      </.config_table>

      <%!-- Voice prompts --%>
      <.section_header title={"Voice prompts (#{length(@voice_prompts)})"} />
      <.config_table rows={@voice_prompts} event="edit_voice_prompt">
        <:col label="Type"></:col>
        <:col label="Name"></:col>
        <:col label="Active"></:col>
        <:row_render :let={vp}>
          <td class="px-4 py-2 font-mono text-xs">{vp.prompt_type}</td>
          <td class="px-4 py-2">{vp.name}</td>
          <td class="px-4 py-2">{if vp.is_active, do: "yes", else: "no"}</td>
        </:row_render>
      </.config_table>

      <%!-- Methodologies --%>
      <.section_header title={"Methodologies (#{length(@methodologies)})"} />
      <.config_table rows={@methodologies} event="edit_methodology">
        <:col label="Name"></:col>
        <:col label="Active"></:col>
        <:row_render :let={m}>
          <td class="px-4 py-2">{m.name}</td>
          <td class="px-4 py-2">{if m.is_active, do: "yes", else: "no"}</td>
        </:row_render>
      </.config_table>

      <%!-- Scenarios --%>
      <.section_header title={"Scenarios (#{length(@scenarios)})"} />
      <.config_table rows={@scenarios} event="edit_scenario">
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
    """
  end

  # ---------------------------------------------------------------------------
  # Sub-components
  # ---------------------------------------------------------------------------

  defp section_header(assigns) do
    assigns = assign_new(assigns, :inner_block, fn -> nil end)

    ~H"""
    <div class="flex items-center justify-between mb-2">
      <h2 class="text-base font-semibold text-gray-700">{@title}</h2>
      <div :if={@inner_block}>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  defp kv_row(assigns) do
    ~H"""
    <div class="flex px-4 py-2 gap-4">
      <span class="text-gray-500 w-48 shrink-0">{@label}</span>
      <span class="font-mono">{@value}</span>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :event, :string, required: true

  slot :col, required: true do
    attr :label, :string, required: true
  end

  slot :row_render, required: true

  defp config_table(assigns) do
    ~H"""
    <div class="overflow-hidden border rounded-lg mb-8">
      <table class="w-full text-sm text-left">
        <thead class="bg-gray-50 text-xs uppercase tracking-wider text-gray-500">
          <tr>
            <th :for={col <- @col} class="px-4 py-3">{col.label}</th>
            <th class="px-4 py-3">Actions</th>
          </tr>
        </thead>
        <tbody class="divide-y">
          <tr :for={row <- @rows} class="hover:bg-gray-50">
            {render_slot(@row_render, row)}
            <td class="px-4 py-2">
              <button
                phx-click={@event}
                phx-value-id={row.id}
                class="text-xs text-blue-600 hover:underline"
              >
                Edit
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
      <label class="block text-sm font-medium text-gray-700 mb-1">{@label}</label>
      <input
        type={@type}
        name={@name}
        value={@form[@field] && @form[@field].value}
        class="w-full border rounded px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-blue-500"
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
      <label class="block text-sm font-medium text-gray-700 mb-1">{@label}</label>
      <textarea
        name={@name}
        rows="5"
        class="w-full border rounded px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-blue-500"
      >{@form[@field] && @form[@field].value}</textarea>
    </div>
    """
  end

  defp form_buttons(assigns) do
    ~H"""
    <div class="flex gap-2 pt-1">
      <button
        type="submit"
        class="px-4 py-2 bg-blue-600 text-white text-sm rounded hover:bg-blue-700"
      >
        Save
      </button>
      <button
        type="button"
        phx-click="cancel_edit"
        class="px-4 py-2 border text-sm rounded hover:bg-gray-50"
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
    |> assign(:voice_prompts, CentralConfig.list_voice_prompts())
    |> assign(:methodologies, CentralConfig.list_methodologies())
    |> assign(:scenarios, CentralConfig.list_scenarios())
    |> assign(:settings, CentralConfig.get_settings())
  end
end
