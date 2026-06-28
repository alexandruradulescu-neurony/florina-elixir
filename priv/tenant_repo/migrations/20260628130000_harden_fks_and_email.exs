defmodule Florina.TenantRepo.Migrations.HardenFksAndEmail do
  use Ecto.Migration

  # Runs inside each tenant schema (BootMigrator injects prefix: "tenant_<id>").
  def change do
    # 1. Email is the SSO identity key — enforce it as unique (case-insensitive).
    #    Prevents duplicate-account races on concurrent first-logins/invites.
    create unique_index(:voice_user, ["lower(email)"],
             where: "email IS NOT NULL",
             name: :voice_user_email_lower_index
           )

    # 2. Stop routine deletes from cascading away meeting / call / audit history.
    #    Deleting a client or visit that still has dependent rows now RAISES
    #    instead of silently destroying call transcripts, recordings, and the
    #    encrypted generation-run audit trail.
    alter table(:voice_visit) do
      modify :client_id, references(:voice_client, on_delete: :restrict),
        from: references(:voice_client, on_delete: :delete_all),
        null: false

      modify :agent_id, references(:voice_user, on_delete: :restrict),
        from: references(:voice_user, on_delete: :delete_all),
        null: false
    end

    alter table(:voice_callattempt) do
      modify :visit_id, references(:voice_visit, type: :bigint, on_delete: :restrict),
        from: references(:voice_visit, type: :bigint, on_delete: :delete_all),
        null: true
    end

    alter table(:voice_generationrun) do
      modify :visit_id, references(:voice_visit, on_delete: :restrict),
        from: references(:voice_visit, on_delete: :delete_all),
        null: true

      modify :client_id, references(:voice_client, on_delete: :restrict),
        from: references(:voice_client, on_delete: :delete_all),
        null: true
    end
  end
end
