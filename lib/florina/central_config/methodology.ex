defmodule Florina.CentralConfig.Methodology do
  @moduledoc """
  Canonical (control-plane) copy of a methodology.

  Lives in the main `Florina.Repo` database — not per-tenant.
  `created_by_id` is a plain integer field; there is no FK to voice_user
  because voice_user exists only in per-tenant databases.

  Table: `voice_methodology` (in the control-plane DB)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_methodology" do
    field :name, :string
    field :description, :string
    field :source_material, :string
    field :ai_summary, :string
    field :is_active, :boolean, default: true
    # Plain integer — no FK (voice_user is per-tenant only)
    field :created_by_id, :integer

    timestamps()
  end

  @required_fields [:name]
  @optional_fields [:description, :source_material, :ai_summary, :is_active, :created_by_id]

  def changeset(methodology, attrs) do
    methodology
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 255)
  end
end
