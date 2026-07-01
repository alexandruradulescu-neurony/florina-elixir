defmodule Florina.TenantRepo.Migrations.AddSmtpSettings do
  use Ecto.Migration

  # Per-tenant outgoing-email (SMTP) credentials for the voice concierge's
  # follow-ups. The password is stored encrypted (Cloak → bytea, like the CRM
  # tokens); the rest are plaintext. Applied to every tenant schema on boot.
  def change do
    alter table(:voice_globalsettings) do
      add :smtp_host, :string
      add :smtp_port, :integer
      add :smtp_username, :string
      add :smtp_password, :binary
      add :smtp_from, :string
      add :smtp_from_name, :string
    end
  end
end
