defmodule Florina.Methodologies.Methodology do
  @moduledoc """
  Meeting preparation methodology (e.g., SPIN Selling, MEDDIC, Challenger).

  `source_material` is a plain string path/URL column — actual upload handling
  is a future concern (Django used FileField).

  Table: `voice_methodology`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_methodology" do
    field :name, :string
    field :description, :string
    # Django FileField — stored as string path/URL; upload handling deferred.
    field :source_material, :string
    field :ai_summary, :string
    field :is_active, :boolean, default: true

    belongs_to :created_by, Florina.Accounts.User

    timestamps()
  end

  @required_fields [:name]
  @optional_fields [:description, :source_material, :ai_summary, :is_active, :created_by_id]

  @doc "Changeset for creating/updating a methodology."
  def changeset(methodology, attrs) do
    methodology
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 255)
  end
end
