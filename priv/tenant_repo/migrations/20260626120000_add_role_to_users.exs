defmodule Florina.TenantRepo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  # Manager/agent role split. Backfills every existing row to "agent" and makes
  # "agent" the default for new rows; the operator promotes the first manager
  # from /admin. Applied to every tenant schema on boot (BootMigrator) and to
  # new tenants by the provisioner's migrate step.
  def change do
    alter table(:voice_user) do
      add :role, :string, null: false, default: "agent"
    end
  end
end
