defmodule Florina.TenantRepo.Migrations.AddCallsEnabledToVisit do
  use Ecto.Migration

  # Manual override for the client-meeting classification: a manager can turn
  # Florina's pre/post calls off for a specific meeting (e.g. a recruiter/vendor
  # meeting that was auto-classified as a client meeting) without deleting it.
  # Existing rows default to true so current client meetings keep calling.
  # Applied to every tenant schema on boot (BootMigrator).
  def change do
    alter table(:voice_visit) do
      add :calls_enabled, :boolean, null: false, default: true
    end
  end
end
