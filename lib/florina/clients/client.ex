defmodule Florina.Clients.Client do
  @moduledoc """
  Client/company synced from CRM. Local copy for AI enrichment.

  Table: `voice_client`
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Florina.Enums

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_client" do
    field :crm_id, :string
    field :name, :string
    field :domain, :string
    field :industry, :string
    # stored "nou" or "existent" (Romanian) — matches Django ClientStatus
    field :status, Ecto.Enum, values: Enums.client_status_values(), default: :new
    field :contacts, {:array, :map}, default: []
    field :deal_history, {:array, :map}, default: []
    field :interaction_history, {:array, :map}, default: []
    field :ai_summary, :string
    field :lessons_learned, :string, default: ""
    field :raw_data, :map, default: %{}
    field :last_synced_at, :utc_datetime

    timestamps()
  end

  @required_fields [:crm_id, :name]
  @optional_fields [
    :domain,
    :industry,
    :status,
    :contacts,
    :deal_history,
    :interaction_history,
    :ai_summary,
    :lessons_learned,
    :raw_data,
    :last_synced_at
  ]

  @doc "Changeset for creating/updating a client record."
  def changeset(client, attrs) do
    client
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:crm_id, max: 100)
    |> validate_length(:name, max: 255)
    |> validate_length(:domain, max: 255)
    |> unique_constraint(:crm_id)
  end
end
