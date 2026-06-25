defmodule Florina.CentralConfig.MegaPrompt do
  @moduledoc """
  Canonical (control-plane) copy of a mega prompt.

  Lives in the main `Florina.Repo` database — not per-tenant.
  `created_by_id` is a plain integer field; no FK to voice_user.

  Table: `voice_megaprompt` (in the control-plane DB)
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
    # Plain integer — no FK (voice_user is per-tenant only)
    field :created_by_id, :integer

    timestamps()
  end

  @required_fields [:domain, :name, :meta_prompt]
  @optional_fields [:is_active, :version, :created_by_id]

  def changeset(mega_prompt, attrs) do
    mega_prompt
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 255)
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint([:domain, :version], name: "megaprompt_unique_domain_version")
    |> unique_constraint(:domain,
      name: "megaprompt_one_active_per_domain",
      message: "an active mega-prompt for this domain already exists"
    )
  end
end
