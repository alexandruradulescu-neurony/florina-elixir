defmodule Florina.Calendar.GoogleCalendarWatch do
  @moduledoc """
  Tracks Google Calendar push notification watch channels.

  Table: `voice_googlecalendarwatch`
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Only created_at, no updated_at in Django model.
  @primary_key {:id, :id, autogenerate: true}

  schema "voice_googlecalendarwatch" do
    belongs_to :user, Florina.Accounts.User

    field :channel_id, :string
    field :resource_id, :string
    field :expiration, :utc_datetime
    field :token, :string, default: ""

    field :created_at, :utc_datetime, autogenerate: false
  end

  @required_fields [:user_id, :channel_id, :resource_id, :expiration]
  @optional_fields [:token, :created_at]

  @doc "Changeset for creating/updating a calendar watch channel."
  def changeset(watch, attrs) do
    watch
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:channel_id, max: 255)
    |> validate_length(:resource_id, max: 255)
    |> validate_length(:token, max: 64)
    |> unique_constraint(:channel_id)
    |> foreign_key_constraint(:user_id)
  end
end
