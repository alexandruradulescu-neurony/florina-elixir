defmodule Florina.Repo.Migrations.CreateCalendarEvents do
  use Ecto.Migration

  def change do
    create table(:calendar_events) do
      add :user_id, references(:voice_user, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :external_event_id, :string, size: 512, null: false
      add :title, :string, size: 1024
      add :description, :text
      add :location, :string, size: 1024
      add :start_time, :utc_datetime, null: false
      add :end_time, :utc_datetime, null: false
      add :attendees, {:array, :map}, null: false, default: []
      add :status, :string, size: 50
      add :raw, :map
      add :synced_at, :utc_datetime
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:calendar_events, [:start_time])

    create unique_index(:calendar_events, [:user_id, :provider, :external_event_id],
             name: :calendar_events_user_provider_extid_index
           )
  end
end
