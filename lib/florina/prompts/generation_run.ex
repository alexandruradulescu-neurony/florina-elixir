defmodule Florina.Prompts.GenerationRun do
  @moduledoc """
  Audit log of every Auto Prompt Assembler run (pre, post, lessons distill).

  Visit is set for PRE_CALL/POST_CALL runs; Client is set for LESSONS_DISTILL runs.

  Fields context_bundle, claude_request, claude_response, parsed_outputs, error
  carry PII (transcripts, manager notes, CRM history, generated prompts) and are
  encrypted at rest using Cloak (AES-GCM-256 via Florina.Vault). They are stored
  as :binary (bytea) columns in PostgreSQL and decrypted transparently on read.

  Note on defaults: Cloak.Ecto types validate defaults at schema load time, which
  requires the vault process to be running. Defaults for encrypted fields are
  therefore applied in the changeset via put_change/3 rather than inline in the
  schema definition.

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

    # Encrypted fields — no schema-level default (Cloak validates defaults at
    # compile time against a running vault; defaults are set in the changeset).
    field :context_bundle, Florina.Encrypted.Map
    field :claude_request, Florina.Encrypted.Binary
    field :claude_response, Florina.Encrypted.Binary
    field :parsed_outputs, Florina.Encrypted.Map
    field :error, Florina.Encrypted.Binary

    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :success, :boolean, default: false

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
    |> put_encrypted_defaults()
    |> foreign_key_constraint(:visit_id)
    |> foreign_key_constraint(:client_id)
    |> foreign_key_constraint(:mega_prompt_id)
    |> foreign_key_constraint(:created_by_id)
  end

  # Apply defaults for encrypted fields only when the field is nil after cast.
  # This mirrors the schema-level defaults the original non-encrypted fields had.
  defp put_encrypted_defaults(changeset) do
    changeset
    |> put_default(:context_bundle, %{})
    |> put_default(:claude_request, "")
    |> put_default(:claude_response, "")
    |> put_default(:parsed_outputs, %{})
    |> put_default(:error, "")
  end

  defp put_default(changeset, field, default) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, default)
      _ -> changeset
    end
  end
end
