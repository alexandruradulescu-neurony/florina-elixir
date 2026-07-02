defmodule Florina.Inbox.InboundEmail do
  @moduledoc """
  An incoming client email the concierge has ingested — parsed, understood, and
  attached to a client/meeting as context.

  `tier` is the sender-trust ceiling, NOT an action taken: `:consequential` means
  the sender matched a known client (a human may later approve a consequential
  action based on it); `:unknown` means an unrecognized sender — read-and-flag
  only. The email content is never itself an action trigger.

  Table: `voice_inbound_email`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  @tiers [:consequential, :unknown]
  @statuses [:new, :read]

  schema "voice_inbound_email" do
    field :message_id, :string
    field :from_email, :string
    field :from_name, :string
    field :subject, :string
    field :body, :string
    field :received_at, :utc_datetime
    field :summary, :string
    field :tier, Ecto.Enum, values: @tiers, default: :unknown
    field :status, Ecto.Enum, values: @statuses, default: :new

    belongs_to :client, Florina.Clients.Client
    belongs_to :visit, Florina.Visits.Visit

    timestamps()
  end

  @doc false
  def changeset(email, attrs) do
    email
    |> cast(attrs, [
      :message_id,
      :from_email,
      :from_name,
      :subject,
      :body,
      :received_at,
      :summary,
      :tier,
      :status,
      :client_id,
      :visit_id
    ])
    # These columns are varchar(255); external email can exceed that. Truncate
    # rather than reject, so one long-header message can't crash ingestion (and
    # poison the whole poll batch). `body`/`summary` are :text — left uncapped.
    |> truncate(:message_id, 255)
    |> truncate(:from_email, 255)
    |> truncate(:from_name, 255)
    |> truncate(:subject, 255)
    |> unique_constraint(:message_id)
  end

  defp truncate(changeset, field, max) do
    case get_change(changeset, field) do
      value when is_binary(value) and byte_size(value) > max ->
        put_change(changeset, field, String.slice(value, 0, max))

      _ ->
        changeset
    end
  end

  @doc "Sender-trust tiers."
  def tiers, do: @tiers
end
