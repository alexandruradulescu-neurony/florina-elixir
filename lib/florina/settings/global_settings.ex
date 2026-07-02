defmodule Florina.Settings.GlobalSettings do
  @moduledoc """
  Singleton model for system-wide per-tenant configuration.

  One row per tenant database (pk=1). Use `load/0` to get-or-create it.

  Table: `voice_globalsettings`
  """
  use Ecto.Schema
  import Ecto.Changeset

  # No inserted_at — Django has only updated_at for this model.
  @timestamps_opts [type: :utc_datetime, inserted_at: false, updated_at: :updated_at]

  schema "voice_globalsettings" do
    field :pre_call_offset_minutes, :integer, default: -60
    field :post_call_offset_minutes, :integer, default: 15
    field :retry_interval_minutes, :integer, default: 5
    field :max_call_attempts_per_phase, :integer, default: 2
    field :max_context_tokens_warn, :integer, default: 50_000

    # Per-tenant CRM credentials. Each tenant syncs its own CRM, so these are
    # tenant-private and never published from the central config.
    # `crm_provider` selects which CRM is active: "pipedrive" | "hubspot".
    # Both providers' credentials are kept so switching doesn't lose them.
    # API tokens are encrypted at rest (Cloak) like OAuth credentials; the
    # domain is not a secret and stays plaintext.
    field :crm_provider, :string, default: "pipedrive"
    field :pipedrive_api_token, Florina.Encrypted.Binary, redact: true
    field :pipedrive_domain, :string
    field :hubspot_api_token, Florina.Encrypted.Binary, redact: true

    # Per-tenant outgoing email (SMTP) for the voice concierge's follow-ups.
    # Password encrypted at rest like the CRM tokens; the rest are plaintext.
    field :smtp_host, :string
    field :smtp_port, :integer
    field :smtp_username, :string
    field :smtp_password, Florina.Encrypted.Binary, redact: true
    field :smtp_from, :string
    field :smtp_from_name, :string

    # Per-tenant incoming email (IMAP) — the same Florina mailbox the concierge
    # reads client replies from. Password encrypted like the SMTP one.
    field :imap_host, :string
    field :imap_port, :integer
    field :imap_username, :string
    field :imap_password, Florina.Encrypted.Binary, redact: true

    # Per-tenant ElevenLabs voice config. Each tenant has its own agent, phone
    # number, API key, and webhook/tool secrets — there is NO shared global
    # config, so voice only works once these are set. Secrets encrypted at rest.
    field :elevenlabs_api_key, Florina.Encrypted.Binary, redact: true
    field :elevenlabs_agent_id, :string
    field :elevenlabs_phone_number_id, :string
    field :elevenlabs_webhook_secret, Florina.Encrypted.Binary, redact: true
    field :elevenlabs_tools_secret, Florina.Encrypted.Binary, redact: true

    field :is_overridden, :boolean, default: false

    belongs_to :default_methodology, Florina.Methodologies.Methodology

    timestamps()
  end

  @cast_fields [
    :pre_call_offset_minutes,
    :post_call_offset_minutes,
    :retry_interval_minutes,
    :max_call_attempts_per_phase,
    :max_context_tokens_warn,
    :crm_provider,
    :pipedrive_api_token,
    :pipedrive_domain,
    :hubspot_api_token,
    :smtp_host,
    :smtp_port,
    :smtp_username,
    :smtp_password,
    :smtp_from,
    :smtp_from_name,
    :imap_host,
    :imap_port,
    :imap_username,
    :imap_password,
    :elevenlabs_api_key,
    :elevenlabs_agent_id,
    :elevenlabs_phone_number_id,
    :elevenlabs_webhook_secret,
    :elevenlabs_tools_secret,
    :default_methodology_id
    # :is_overridden is intentionally NOT castable — it's a publish-control flag
    # set only by app code (`Settings.update/1` via put_change), never from params.
  ]

  @crm_providers ~w(pipedrive hubspot)

  @doc "Valid CRM provider values."
  def crm_providers, do: @crm_providers

  @doc "Get-or-create the singleton settings row (pk=1) using TenantRepo."
  def load do
    alias Florina.TenantRepo

    case TenantRepo.get(__MODULE__, 1) do
      nil ->
        # Insert with pk=1; ignore conflict (race-safe). With on_conflict: :nothing
        # a losing insert returns the in-memory struct (defaults), NOT the row a
        # concurrent writer persisted — so always re-read to get the real values.
        %__MODULE__{id: 1}
        |> change()
        |> TenantRepo.insert(on_conflict: :nothing, conflict_target: :id)

        TenantRepo.get!(__MODULE__, 1)

      row ->
        row
    end
  end

  @doc "Changeset for updating global settings."
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, @cast_fields)
    |> validate_inclusion(:crm_provider, @crm_providers)
    |> validate_pipedrive_domain()
    |> validate_smtp()
    |> Florina.Settings.GlobalSettings.validate_scheduling()
  end

  # Light bounds for the SMTP + IMAP fields — only applied to fields actually
  # present in the changeset (nil/unchanged fields are skipped by the validators).
  defp validate_smtp(changeset) do
    changeset
    |> validate_number(:smtp_port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_number(:imap_port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_length(:smtp_host, max: 255)
    |> validate_length(:smtp_username, max: 255)
    |> validate_length(:smtp_from, max: 255)
    |> validate_length(:smtp_from_name, max: 255)
    |> validate_length(:imap_host, max: 255)
    |> validate_length(:imap_username, max: 255)
    |> validate_length(:elevenlabs_agent_id, max: 255)
    |> validate_length(:elevenlabs_phone_number_id, max: 255)
  end

  # The Pipedrive domain is interpolated into the API base URL
  # (https://<domain>.pipedrive.com/...). Restrict it to a single DNS label so a
  # manager-supplied value containing "/", "@", "?", "#", ":" or whitespace can't
  # redirect outbound requests (and the tenant's API token) to an arbitrary host
  # (SSRF). nil/blank is allowed (clears the field → env fallback).
  @pipedrive_domain_re ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/i
  defp validate_pipedrive_domain(changeset) do
    validate_format(changeset, :pipedrive_domain, @pipedrive_domain_re,
      message: ~s(must be just your Pipedrive subdomain, e.g. "acme" — letters, numbers, hyphens)
    )
  end

  @doc """
  Server-side bounds for the scheduling fields, shared with the central config
  schema. Offsets may be negative (before the meeting); intervals/caps/thresholds
  must be positive and within sane ceilings so a tampered or fat-fingered form
  can't submit zero/negative/huge values.
  """
  def validate_scheduling(changeset) do
    import Ecto.Changeset

    changeset
    # Floor at the call-scan cadence (every 5 min): a retry interval finer than the
    # scan can't be honored (the scheduler only re-evaluates every 5 minutes), and
    # values below it would make two attempt windows overlap. Default is 5.
    |> validate_number(:retry_interval_minutes,
      greater_than_or_equal_to: 5,
      less_than_or_equal_to: 1440
    )
    |> validate_number(:max_call_attempts_per_phase,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 10
    )
    |> validate_number(:max_context_tokens_warn,
      greater_than: 0,
      less_than_or_equal_to: 1_000_000
    )
    |> validate_number(:pre_call_offset_minutes,
      greater_than_or_equal_to: -1440,
      less_than_or_equal_to: 1440
    )
    |> validate_number(:post_call_offset_minutes,
      greater_than_or_equal_to: -1440,
      less_than_or_equal_to: 1440
    )
  end
end
