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
    # Provider-supplied strings can exceed the column limits (a long event title
    # or a recurring-instance id). Truncate so one oversized event can't crash the
    # whole agent's calendar sync. (`description` is :text — left uncapped.)
    |> truncate(:external_event_id, 512)
    |> truncate(:title, 1024)
    |> truncate(:location, 1024)
    |> truncate(:status, 50)
    |> unique_constraint([:user_id, :provider, :external_event_id],
      name: :calendar_events_user_provider_extid_index
    )
  end

  defp truncate(changeset, field, max) do
    case get_change(changeset, field) do
      value when is_binary(value) and byte_size(value) > max ->
        put_change(changeset, field, String.slice(value, 0, max))

      _ ->
        changeset
    end
  end
end
