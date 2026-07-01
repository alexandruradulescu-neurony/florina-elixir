defmodule Florina.Clients.Document do
  @moduledoc """
  A file uploaded against a client (a PDF, Word `.docx`, or text/CSV file).

  The bytes live on the uploads volume (see `Florina.Storage`); this row is the
  metadata plus the plain text extracted for Florina's call-prep. `extraction_status`
  tracks that background text extraction: `:pending` → `:done` / `:failed` /
  `:unsupported`.

  Table: `voice_client_document`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  @statuses [:pending, :done, :failed, :unsupported]

  schema "voice_client_document" do
    field :original_filename, :string
    field :stored_filename, :string
    field :content_type, :string
    field :byte_size, :integer, default: 0
    field :extraction_status, Ecto.Enum, values: @statuses, default: :pending
    field :extracted_text, :string
    field :uploaded_by_agent_id, :id

    belongs_to :client, Florina.Clients.Client

    timestamps()
  end

  @doc false
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :client_id,
      :original_filename,
      :stored_filename,
      :content_type,
      :byte_size,
      :extraction_status,
      :extracted_text,
      :uploaded_by_agent_id
    ])
    |> validate_required([:client_id, :original_filename, :stored_filename])
    |> validate_length(:original_filename, max: 255)
    |> validate_length(:stored_filename, max: 255)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> assoc_constraint(:client)
  end

  @doc "Extraction statuses, in lifecycle order."
  def statuses, do: @statuses
end
