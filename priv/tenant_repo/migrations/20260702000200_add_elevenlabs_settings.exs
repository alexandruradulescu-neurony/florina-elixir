defmodule Florina.TenantRepo.Migrations.AddElevenlabsSettings do
  use Ecto.Migration

  # Per-tenant ElevenLabs voice config. Each tenant runs its own ElevenLabs agent,
  # phone number, API key, and webhook/tool secrets — the voice product is fully
  # tenant-isolated, with no shared global credentials. Secrets are stored
  # encrypted (Cloak → bytea, like the SMTP/CRM ones); the ids are plaintext.
  def change do
    alter table(:voice_globalsettings) do
      add :elevenlabs_api_key, :binary
      add :elevenlabs_agent_id, :string
      add :elevenlabs_phone_number_id, :string
      add :elevenlabs_webhook_secret, :binary
      add :elevenlabs_tools_secret, :binary
    end
  end
end
