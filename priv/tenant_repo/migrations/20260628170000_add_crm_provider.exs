defmodule Florina.TenantRepo.Migrations.AddCrmProvider do
  use Ecto.Migration

  # Per-tenant CRM provider selector + HubSpot credential. The provider chooses
  # which CRM (pipedrive | hubspot) the sync pulls from; both providers' creds are
  # stored so switching doesn't lose them. Defaults preserve existing behaviour
  # (pipedrive). Applied to every tenant schema on boot (BootMigrator).
  def change do
    alter table(:voice_globalsettings) do
      add :crm_provider, :string, null: false, default: "pipedrive"
      add :hubspot_api_token, :string
    end
  end
end
