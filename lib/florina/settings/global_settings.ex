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
    field :pipedrive_api_token, Florina.Encrypted.Binary
    field :pipedrive_domain, :string
    field :hubspot_api_token, Florina.Encrypted.Binary

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
        # Insert with pk=1; ignore conflict (race-safe)
        %__MODULE__{id: 1}
        |> change()
        |> TenantRepo.insert(on_conflict: :nothing, conflict_target: :id)
        |> case do
          {:ok, row} -> row
          {:error, _} -> TenantRepo.get!(__MODULE__, 1)
        end

      row ->
        row
    end
  end

  @doc "Changeset for updating global settings."
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, @cast_fields)
    |> validate_inclusion(:crm_provider, @crm_providers)
    |> Florina.Settings.GlobalSettings.validate_scheduling()
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
    |> validate_number(:retry_interval_minutes, greater_than: 0, less_than_or_equal_to: 1440)
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
