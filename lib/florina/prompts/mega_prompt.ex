defmodule Florina.Prompts.MegaPrompt do
  @moduledoc """
  Versioned meta-prompt for the Auto Prompt Assembler.

  Edit always creates a new version (never in-place). At most one active
  version per domain at a time — enforced by a partial unique index.
  Old versions are retained forever; rollback = activating an older row.

  Table: `voice_megaprompt`
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Florina.Enums

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_megaprompt" do
    field :domain, Ecto.Enum, values: Enums.mega_prompt_domain_values()
    field :name, :string
    field :meta_prompt, :string
    field :is_active, :boolean, default: false
    field :version, :integer, default: 1

    belongs_to :created_by, Florina.Accounts.User

    timestamps()
  end

  @required_fields [:domain, :name, :meta_prompt]
  @optional_fields [:is_active, :version, :created_by_id]

  @doc "Changeset for creating/updating a mega prompt version."
  def changeset(mega_prompt, attrs) do
    mega_prompt
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 255)
    |> validate_number(:version, greater_than: 0)
    # unique (domain, version)
    |> unique_constraint([:domain, :version], name: "megaprompt_unique_domain_version")
    # unique active per domain (partial unique index)
    |> unique_constraint(:domain,
      name: "megaprompt_one_active_per_domain",
      message: "an active mega-prompt for this domain already exists"
    )
  end
end
