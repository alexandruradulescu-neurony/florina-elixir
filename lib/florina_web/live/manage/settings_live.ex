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
     |> assign(:crm_provider, settings.crm_provider || "pipedrive")
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

  # Live toggle of which provider's credential fields are shown (not persisted
  # until Save). Fired by the provider dropdown's phx-change.
  def handle_event("select_crm", %{"crm" => %{"crm_provider" => provider}}, socket) do
    {:noreply, assign(socket, :crm_provider, provider)}
  end

  def handle_event("save_crm", %{"crm" => params}, socket) do
    case Settings.update_crm(params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:settings, settings)
         |> assign(:crm_provider, settings.crm_provider || "pipedrive")
         |> put_flash(:info, "CRM credentials saved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save CRM credentials.")}
    end
  end

  def handle_event("save_smtp", %{"smtp" => params}, socket) do
    case Settings.update_smtp(params) do
      {:ok, settings} ->
        {:noreply,
         socket |> assign(:settings, settings) |> put_flash(:info, "Email settings saved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save email settings.")}
    end
  end

  def handle_event("save_imap", %{"imap" => params}, socket) do
    case Settings.update_imap(params) do
      {:ok, settings} ->
        {:noreply,
         socket |> assign(:settings, settings) |> put_flash(:info, "Email settings saved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save email settings.")}
    end
  end

  def handle_event("save_elevenlabs", %{"elevenlabs" => params}, socket) do
    case Settings.update_elevenlabs(params) do
      {:ok, settings} ->
        {:noreply,
         socket |> assign(:settings, settings) |> put_flash(:info, "Voice settings saved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save voice settings.")}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  defp token_placeholder(saved) when saved in [nil, ""], do: "Paste the API token"
  defp token_placeholder(_saved), do: "•••••••• (a token is saved — leave blank to keep it)"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:settings}
    >
      <.header micro="Manage">
        Settings
        <:subtitle>System-wide call timing and defaults for this workspace.</:subtitle>
      </.header>

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
            field={@form[:max_call_attempts_per_phase]}
            type="number"
            label="Call attempts per phase"
            min="1"
            max="10"
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

        <aside class="text-sm text-gray-500 dark:text-gray-400 space-y-3">
          <p>
            <span class="font-medium text-gray-900 dark:text-white">Pre / post offset</span>
            — when Florina dials relative to the meeting (negative = before).
          </p>
          <p>
            <span class="font-medium text-gray-900 dark:text-white">Call attempts per phase</span>
            — how many times Florina tries each pre/post call.
          </p>
          <p>
            <span class="font-medium text-gray-900 dark:text-white">Retry interval</span>
            — wait between those attempts.
          </p>
          <p>
            <span class="font-medium text-gray-900 dark:text-white">Token-warning threshold</span>
            — flags a generation run whose context exceeds this.
          </p>
          <p>
            <span class="font-medium text-gray-900 dark:text-white">Default methodology</span>
            — fallback when no agent or visit override is set.
          </p>
        </aside>
      </div>

      <div class="mt-12 border-t border-gray-200 dark:border-white/10 pt-8 max-w-xl">
        <h2 class="text-xl font-extrabold tracking-[-0.01em] text-gray-900 dark:text-white">
          CRM integration
        </h2>
        <p class="text-sm text-gray-500 dark:text-gray-400 mb-5">
          Choose your CRM, then enter that CRM's credentials below. Florina syncs clients
          from the CRM you select here. A blank token keeps the one already saved.
        </p>
        <.form
          :let={f}
          for={
            to_form(
              %{
                "crm_provider" => @crm_provider,
                "pipedrive_domain" => @settings.pipedrive_domain || ""
              },
              as: :crm
            )
          }
          id="crm-form"
          phx-submit="save_crm"
          class="space-y-5"
        >
          <.input
            field={f[:crm_provider]}
            type="select"
            label="CRM provider"
            options={[{"Pipedrive", "pipedrive"}, {"HubSpot", "hubspot"}]}
            phx-change="select_crm"
          />

          <fieldset
            :if={@crm_provider == "pipedrive"}
            class="border border-gray-200 dark:border-white/10 rounded-lg p-4 space-y-4"
          >
            <legend class="px-1 text-sm font-medium text-gray-700 dark:text-gray-300">
              Pipedrive
            </legend>
            <.input
              field={f[:pipedrive_domain]}
              type="text"
              label="Pipedrive domain"
              placeholder="yourcompany"
            />
            <.input
              field={f[:pipedrive_api_token]}
              value=""
              type="password"
              label="Pipedrive API token"
              placeholder={token_placeholder(@settings.pipedrive_api_token)}
            />
            <label
              :if={@settings.pipedrive_api_token}
              class="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400"
            >
              <input type="checkbox" name="crm[clear_pipedrive_token]" value="true" class="rounded" />
              Remove the saved Pipedrive token
            </label>
          </fieldset>

          <fieldset
            :if={@crm_provider == "hubspot"}
            class="border border-gray-200 dark:border-white/10 rounded-lg p-4 space-y-4"
          >
            <legend class="px-1 text-sm font-medium text-gray-700 dark:text-gray-300">
              HubSpot
            </legend>
            <.input
              field={f[:hubspot_api_token]}
              value=""
              type="password"
              label="HubSpot private-app token"
              placeholder={token_placeholder(@settings.hubspot_api_token)}
            />
            <label
              :if={@settings.hubspot_api_token}
              class="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400"
            >
              <input type="checkbox" name="crm[clear_hubspot_token]" value="true" class="rounded" />
              Remove the saved HubSpot token
            </label>
            <p class="text-xs text-gray-400">
              Create a Private App in HubSpot (Settings → Integrations → Private Apps) with
              CRM read scopes, then paste its access token here.
            </p>
          </fieldset>

          <.button type="submit" variant="primary">Save CRM settings</.button>
        </.form>
      </div>

      <div class="mt-12 border-t border-gray-200 dark:border-white/10 pt-8 max-w-xl">
        <h2 class="text-xl font-extrabold tracking-[-0.01em] text-gray-900 dark:text-white">
          Outgoing email (SMTP)
        </h2>
        <p class="text-sm text-gray-500 dark:text-gray-400 mb-5">
          The mailbox Florina sends follow-up emails from. A blank password keeps the one
          already saved.
        </p>
        <.form
          :let={f}
          for={
            to_form(
              %{
                "smtp_host" => @settings.smtp_host || "",
                "smtp_port" => @settings.smtp_port || "",
                "smtp_username" => @settings.smtp_username || "",
                "smtp_from" => @settings.smtp_from || "",
                "smtp_from_name" => @settings.smtp_from_name || ""
              },
              as: :smtp
            )
          }
          id="smtp-form"
          phx-submit="save_smtp"
          class="space-y-5"
        >
          <.input
            field={f[:smtp_from]}
            type="text"
            label="From address"
            placeholder="florina@yourcompany.com"
          />
          <.input field={f[:smtp_from_name]} type="text" label="From name" placeholder="Florina" />
          <.input
            field={f[:smtp_host]}
            type="text"
            label="SMTP host"
            placeholder="smtp.yourcompany.com"
          />
          <.input field={f[:smtp_port]} type="number" label="SMTP port" placeholder="587" />
          <.input field={f[:smtp_username]} type="text" label="SMTP username" />
          <.input
            field={f[:smtp_password]}
            value=""
            type="password"
            label="SMTP password"
            placeholder={token_placeholder(@settings.smtp_password)}
          />
          <label
            :if={@settings.smtp_password}
            class="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400"
          >
            <input type="checkbox" name="smtp[clear_smtp_password]" value="true" class="rounded" />
            Remove the saved password
          </label>
          <.button type="submit" variant="primary">Save email settings</.button>
        </.form>
      </div>

      <div class="mt-12 border-t border-gray-200 dark:border-white/10 pt-8 max-w-xl">
        <h2 class="text-xl font-extrabold tracking-[-0.01em] text-gray-900 dark:text-white">
          Incoming email (IMAP)
        </h2>
        <p class="text-sm text-gray-500 dark:text-gray-400 mb-5">
          The same Florina mailbox, for reading client replies. A blank password keeps the
          one already saved.
        </p>
        <.form
          :let={f}
          for={
            to_form(
              %{
                "imap_host" => @settings.imap_host || "",
                "imap_port" => @settings.imap_port || "",
                "imap_username" => @settings.imap_username || ""
              },
              as: :imap
            )
          }
          id="imap-form"
          phx-submit="save_imap"
          class="space-y-5"
        >
          <.input
            field={f[:imap_host]}
            type="text"
            label="IMAP host"
            placeholder="imap.yourcompany.com"
          />
          <.input field={f[:imap_port]} type="number" label="IMAP port" placeholder="993" />
          <.input field={f[:imap_username]} type="text" label="IMAP username" />
          <.input
            field={f[:imap_password]}
            value=""
            type="password"
            label="IMAP password"
            placeholder={token_placeholder(@settings.imap_password)}
          />
          <label
            :if={@settings.imap_password}
            class="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400"
          >
            <input type="checkbox" name="imap[clear_imap_password]" value="true" class="rounded" />
            Remove the saved password
          </label>
          <.button type="submit" variant="primary">Save email settings</.button>
        </.form>
      </div>

      <div class="mt-12 border-t border-gray-200 dark:border-white/10 pt-8 max-w-xl">
        <h2 class="text-xl font-extrabold tracking-[-0.01em] text-gray-900 dark:text-white">
          Voice (ElevenLabs)
        </h2>
        <p class="text-sm text-gray-500 dark:text-gray-400 mb-5">
          This workspace's own ElevenLabs account. Voice calls (outbound briefings and the
          inbound concierge) work only once these are filled in. Blank secrets keep the ones
          already saved.
        </p>
        <.form
          :let={f}
          for={
            to_form(
              %{
                "elevenlabs_agent_id" => @settings.elevenlabs_agent_id || "",
                "elevenlabs_phone_number_id" => @settings.elevenlabs_phone_number_id || ""
              },
              as: :elevenlabs
            )
          }
          id="elevenlabs-form"
          phx-submit="save_elevenlabs"
          class="space-y-5"
        >
          <.input field={f[:elevenlabs_agent_id]} type="text" label="Agent ID" />
          <.input field={f[:elevenlabs_phone_number_id]} type="text" label="Phone number ID" />
          <.input
            field={f[:elevenlabs_api_key]}
            value=""
            type="password"
            label="API key"
            placeholder={token_placeholder(@settings.elevenlabs_api_key)}
          />
          <.secret_clear field="elevenlabs_api_key" saved={@settings.elevenlabs_api_key} />
          <.input
            field={f[:elevenlabs_webhook_secret]}
            value=""
            type="password"
            label="Webhook secret"
            placeholder={token_placeholder(@settings.elevenlabs_webhook_secret)}
          />
          <.secret_clear
            field="elevenlabs_webhook_secret"
            saved={@settings.elevenlabs_webhook_secret}
          />
          <.input
            field={f[:elevenlabs_tools_secret]}
            value=""
            type="password"
            label="Tools secret"
            placeholder={token_placeholder(@settings.elevenlabs_tools_secret)}
          />
          <.secret_clear field="elevenlabs_tools_secret" saved={@settings.elevenlabs_tools_secret} />
          <.button type="submit" variant="primary">Save voice settings</.button>
        </.form>
      </div>
    </Layouts.agent_app>
    """
  end

  # A "remove the saved secret" checkbox, shown only when one is stored.
  attr :field, :string, required: true
  attr :saved, :any, required: true

  defp secret_clear(assigns) do
    ~H"""
    <label
      :if={@saved}
      class="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400"
    >
      <input type="checkbox" name={"elevenlabs[clear_#{@field}]"} value="true" class="rounded" />
      Remove the saved value
    </label>
    """
  end
end
