defmodule Florina.TenantRepo.Migrations.AddVoiceInboundEmail do
  use Ecto.Migration

  # Incoming client emails the concierge has ingested: parsed + understood +
  # attached to a client/meeting as context. `tier` records what the message is
  # allowed to cause (harmless / consequential / unknown); the content itself is
  # never an action trigger. `message_id` dedups repeated fetches.
  def change do
    create table(:voice_inbound_email) do
      add :message_id, :string
      add :from_email, :string
      add :from_name, :string
      add :subject, :string
      add :body, :text
      add :received_at, :utc_datetime
      add :summary, :text
      add :tier, :string, null: false, default: "unknown"
      add :status, :string, null: false, default: "new"
      add :client_id, references(:voice_client, on_delete: :nilify_all)
      add :visit_id, references(:voice_visit, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at)
    end

    create index(:voice_inbound_email, [:client_id])
    create unique_index(:voice_inbound_email, [:message_id])
  end
end
