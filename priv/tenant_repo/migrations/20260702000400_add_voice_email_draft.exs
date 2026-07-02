defmodule Florina.TenantRepo.Migrations.AddVoiceEmailDraft do
  use Ecto.Migration

  # Per-tenant draft for a concierge follow-up email. The recipient, dictated
  # notes and meeting/client labels live HERE, in the tenant's own schema — never
  # in the shared public `oban_jobs` args, which only carry the draft id.
  def change do
    create table(:voice_email_draft) do
      add :recipient, :string, null: false
      add :purpose, :string, null: false
      add :notes, :text
      add :client_name, :string
      add :meeting_title, :string
      add :meeting_time, :string
      add :agent_id, :integer
      add :visit_id, :integer
      add :client_id, :integer

      timestamps(type: :utc_datetime)
    end
  end
end
