defmodule Florina.TenantRepo.Migrations.DropDeadCallattemptColumns do
  use Ecto.Migration

  # The Elixir port creates one `voice_callattempt` row per dial and counts rows
  # directly, so the Django-era scheduling columns (`scheduled_time`,
  # `executed_at`, `retry_count`, `scheduled_offset_minutes`) and the index over
  # (`scheduled_time`, `status`) are dead — the `CallAttempt` schema maps none of
  # them and nothing in the codebase references them.

  def up do
    drop_if_exists index(:voice_callattempt, [:scheduled_time, :status],
                     name: "voice_calla_schedul_status_idx"
                   )

    alter table(:voice_callattempt) do
      remove :scheduled_time
      remove :executed_at
      remove :retry_count
      remove :scheduled_offset_minutes
    end
  end

  def down do
    alter table(:voice_callattempt) do
      add :scheduled_offset_minutes, :integer
      add :scheduled_time, :utc_datetime
      add :executed_at, :utc_datetime
      add :retry_count, :integer, null: false, default: 0
    end

    create index(:voice_callattempt, [:scheduled_time, :status],
             name: "voice_calla_schedul_status_idx"
           )
  end
end
