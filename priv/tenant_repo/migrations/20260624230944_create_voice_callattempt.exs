defmodule Florina.TenantRepo.Migrations.CreateVoiceCallattempt do
  # The calls table now lives in EACH tenant's database (one per customer),
  # not in the control-plane database. Columns mirror the schema mapped by
  # `Florina.Calls.CallAttempt`.
  use Ecto.Migration

  def change do
    create_if_not_exists table(:voice_callattempt) do
      add :visit_id, :bigint
      add :phase, :string, size: 20
      add :scheduled_offset_minutes, :integer
      add :external_call_id, :string, size: 100
      add :status, :string, size: 20, null: false, default: "SCHEDULED"
      add :recording_url, :string
      add :transcript, :text
      add :summary, :text
      add :summary_title, :string
      add :analysis, :map, null: false, default: %{}
      add :scheduled_time, :utc_datetime
      add :executed_at, :utc_datetime
      add :retry_count, :integer, null: false, default: 0
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create_if_not_exists index(:voice_callattempt, [:external_call_id])
    create_if_not_exists index(:voice_callattempt, [:status])
  end
end
