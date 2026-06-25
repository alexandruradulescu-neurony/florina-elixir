defmodule Florina.Scenarios.Scenario do
  @moduledoc """
  Visit scenario type (discovery / follow-up / closing / debrief / other).

  Table: `voice_scenario`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_scenario" do
    field :name, :string
    field :slug, :string
    field :description, :string, default: ""
    field :is_active, :boolean, default: true

    timestamps()
  end

  @required_fields [:name, :slug]
  @optional_fields [:description, :is_active]

  @doc "Changeset for creating/updating a scenario."
  def changeset(scenario, attrs) do
    scenario
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 120)
    |> validate_length(:slug, max: 120)
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
