defmodule Florina.Calls.VoicePrompt do
  @moduledoc """
  Editable system prompts for the AI voice agent (ElevenLabs).

  Only one active prompt per `prompt_type` (PRE/POST) is allowed at a time,
  enforced by a partial unique index on the DB layer.

  Table: `voice_voiceprompt`
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Florina.Enums

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_voiceprompt" do
    field :name, :string
    field :system_prompt, :string
    field :first_message, :string
    # stored "PRE" or "POST"
    field :prompt_type, Ecto.Enum, values: Enums.call_phase_values()
    field :is_active, :boolean, default: true

    timestamps()
  end

  @required_fields [:name, :system_prompt, :prompt_type]
  @optional_fields [:first_message, :is_active]

  @doc "Changeset for creating/updating a voice prompt."
  def changeset(voice_prompt, attrs) do
    voice_prompt
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 100)
    |> validate_length(:prompt_type, max: 20)
    # DB enforces: only one active prompt per prompt_type (partial unique index)
    |> unique_constraint(:prompt_type,
      name: "unique_active_prompt",
      message: "an active prompt for this type already exists"
    )
  end
end
