defmodule Florina.Calendar.Event do
  @moduledoc "A synced calendar event (per tenant, per agent). Backs the merged calendar."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]
  @providers [:google, :microsoft]

  schema "calendar_events" do
    belongs_to :user, Florina.Accounts.User
    field :provider, Ecto.Enum, values: @providers
    field :external_event_id, :string
    field :title, :string
    field :description, :string
    field :location, :string
    field :start_time, :utc_datetime
    field :end_time, :utc_datetime
    field :attendees, {:array, :map}, default: []
    field :status, :string
    field :raw, :map
    field :synced_at, :utc_datetime
    timestamps()
  end

  @fields [
    :user_id,
    :provider,
    :external_event_id,
    :title,
    :description,
    :location,
    :start_time,
    :end_time,
    :attendees,
    :status,
    :raw,
    :synced_at
  ]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :provider, :external_event_id, :start_time, :end_time])
    |> unique_constraint([:user_id, :provider, :external_event_id],
      name: :calendar_events_user_provider_extid_index
    )
  end
end
