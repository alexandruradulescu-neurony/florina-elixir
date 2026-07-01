defmodule Florina.TenantRepo.Migrations.AddVoiceClientDocument do
  use Ecto.Migration

  # Per-client uploaded documents. The bytes live on the mounted uploads volume
  # (<uploads_root>/tenant_<id>/client_<id>/<stored_filename>); this row holds the
  # metadata plus the plain text Florina extracts for call-prep. Applied to every
  # tenant schema on boot (BootMigrator). Deleting a client cascades its documents.
  def change do
    create table(:voice_client_document) do
      add :client_id, references(:voice_client, on_delete: :delete_all), null: false
      add :original_filename, :string, null: false
      add :stored_filename, :string, null: false
      add :content_type, :string
      add :byte_size, :bigint, null: false, default: 0
      add :extraction_status, :string, null: false, default: "pending"
      add :extracted_text, :text
      add :uploaded_by_agent_id, references(:voice_user, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at)
    end

    create index(:voice_client_document, [:client_id])
  end
end
