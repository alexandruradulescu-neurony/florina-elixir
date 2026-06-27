defmodule Florina.TenantRepo.Migrations.AddMaxCallAttempts do
  use Ecto.Migration

  # Number of dial attempts per phase (pre/post) — now a tenant setting instead
  # of a hardcoded constant. Default 2 preserves prior behavior. Applied to every
  # tenant schema on boot (BootMigrator).
  def change do
    alter table(:voice_globalsettings) do
      add :max_call_attempts_per_phase, :integer, null: false, default: 2
    end
  end
end
