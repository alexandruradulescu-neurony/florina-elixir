defmodule Florina.Repo.Migrations.AddMaxCallAttemptsToCentralConfig do
  use Ecto.Migration

  # Mirror the per-tenant `max_call_attempts_per_phase` setting in the
  # control-plane voice_globalsettings so it can be set centrally and published
  # down to tenants. Default 2 matches the per-tenant default.
  def change do
    alter table(:voice_globalsettings) do
      add :max_call_attempts_per_phase, :integer, null: false, default: 2
    end
  end
end
