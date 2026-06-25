defmodule Florina.CentralConfig.VoicePrompt do
  @moduledoc """
  Canonical (control-plane) copy of a voice prompt.

  Lives in the main `Florina.Repo` database — not per-tenant.
  Only one active prompt per prompt_type (PRE/POST) enforced by partial unique index.

  Table: `voice_voiceprompt` (in the control-plane DB)
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Florina.Enums

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_voiceprompt" do
    field :name, :string
    field :system_prompt, :string
    field :first_message, :string
    field :prompt_type, Ecto.Enum, values: Enums.call_phase_values()
    field :is_active, :boolean, default: true

    timestamps()
  end

  @required_fields [:name, :system_prompt, :prompt_type]
  @optional_fields [:first_message, :is_active]

  def changeset(voice_prompt, attrs) do
    voice_prompt
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 100)
    |> unique_constraint(:prompt_type,
      name: "unique_active_prompt",
      message: "an active prompt for this type already exists"
    )
  end
end
