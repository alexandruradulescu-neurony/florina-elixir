defmodule Florina.TenantRepo.Migrations.AddPipedriveCredentials do
  use Ecto.Migration

  # Per-tenant Pipedrive (CRM) credentials. Replaces the single global env token
  # so each tenant syncs its own CRM. Nullable — a blank value falls back to the
  # global env credential. Applied to every tenant schema on boot (BootMigrator).
  def change do
    alter table(:voice_globalsettings) do
      add :pipedrive_api_token, :string
      add :pipedrive_domain, :string
    end
  end
end
