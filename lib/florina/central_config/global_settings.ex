defmodule Florina.CentralConfig.GlobalSettings do
  @moduledoc """
  Canonical (control-plane) singleton for default system-wide settings.

  One row, pk=1. `default_methodology_id` has a proper FK here because
  both voice_methodology and voice_globalsettings are in the control-plane DB.

  Table: `voice_globalsettings` (in the control-plane DB)
  """
  use Ecto.Schema
  import Ecto.Changeset

  # No inserted_at — mirrors the per-tenant schema (Django auto_now only).
  @timestamps_opts [type: :utc_datetime, inserted_at: false, updated_at: :updated_at]

  schema "voice_globalsettings" do
    field :pre_call_offset_minutes, :integer, default: -60
    field :post_call_offset_minutes, :integer, default: 15
    field :retry_interval_minutes, :integer, default: 5
    field :max_call_attempts_per_phase, :integer, default: 2
    field :max_context_tokens_warn, :integer, default: 50_000

    belongs_to :default_methodology, Florina.CentralConfig.Methodology

    timestamps()
  end

  @cast_fields [
    :pre_call_offset_minutes,
    :post_call_offset_minutes,
    :retry_interval_minutes,
    :max_call_attempts_per_phase,
    :max_context_tokens_warn,
    :default_methodology_id
  ]

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, @cast_fields)
    # Same scheduling bounds as the per-tenant settings (shared validator).
    |> Florina.Settings.GlobalSettings.validate_scheduling()
  end
end
