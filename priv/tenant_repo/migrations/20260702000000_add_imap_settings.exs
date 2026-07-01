defmodule Florina.TenantRepo.Migrations.AddImapSettings do
  use Ecto.Migration

  # Per-tenant incoming-email (IMAP) credentials for the Florina mailbox the
  # concierge reads. Password encrypted (bytea) like the SMTP/CRM secrets.
  def change do
    alter table(:voice_globalsettings) do
      add :imap_host, :string
      add :imap_port, :integer
      add :imap_username, :string
      add :imap_password, :binary
    end
  end
end
