defmodule Florina.Prompts.GenerationRun do
  @moduledoc """
  Audit log of every Auto Prompt Assembler run (pre, post, lessons distill).

  Visit is set for PRE_CALL/POST_CALL runs; Client is set for LESSONS_DISTILL runs.

  Fields context_bundle, claude_request, claude_response, parsed_outputs, error
  carry PII (transcripts, manager notes, CRM history, generated prompts) and are
  encrypted at rest in Django via Fernet. For now they are stored as plain
  `:text`/`:map` columns.
  # TODO: encrypt at rest (Cloak) — same fields as GoogleOauthCredential secrets.

  Table: `voice_generationrun`
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Florina.Enums

  # GenerationRun has only created_at (no updated_at in Django)
  @primary_key {:id, :id, autogenerate: true}

  schema "voice_generationrun" do
    belongs_to :visit, Florina.Visits.Visit
    belongs_to :client, Florina.Clients.Client
    belongs_to :mega_prompt, Florina.Prompts.MegaPrompt
    belongs_to :created_by, Florina.Accounts.User

    field :domain, Ecto.Enum, values: Enums.mega_prompt_domain_values()
    field :triggered_by, Ecto.Enum, values: Enums.triggered_by_values()

    # TODO: encrypt at rest (Cloak)
    field :context_bundle, :map, default: %{}
    # TODO: encrypt at rest (Cloak)
    field :claude_request, :string, default: ""
    # TODO: encrypt at rest (Cloak)
    field :claude_response, :string, default: ""
    # TODO: encrypt at rest (Cloak)
    field :parsed_outputs, :map, default: %{}
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :success, :boolean, default: false
    # TODO: encrypt at rest (Cloak)
    field :error, :string, default: ""

    field :created_at, :utc_datetime, autogenerate: false
  end

  @required_fields [:domain, :triggered_by]
  @optional_fields [
    :visit_id,
    :client_id,
    :mega_prompt_id,
    :created_by_id,
    :context_bundle,
    :claude_request,
    :claude_response,
    :parsed_outputs,
    :input_tokens,
    :output_tokens,
    :success,
    :error,
    :created_at
  ]

  @doc "Changeset for creating a generation run audit record."
  def changeset(run, attrs) do
    run
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:visit_id)
    |> foreign_key_constraint(:client_id)
    |> foreign_key_constraint(:mega_prompt_id)
    |> foreign_key_constraint(:created_by_id)
  end
end
