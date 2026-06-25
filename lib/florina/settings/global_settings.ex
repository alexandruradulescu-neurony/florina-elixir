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
    field :max_context_tokens_warn, :integer, default: 50_000

    field :is_overridden, :boolean, default: false

    belongs_to :default_methodology, Florina.Methodologies.Methodology

    timestamps()
  end

  @cast_fields [
    :pre_call_offset_minutes,
    :post_call_offset_minutes,
    :retry_interval_minutes,
    :max_context_tokens_warn,
    :default_methodology_id,
    :is_overridden
  ]

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
  end
end
