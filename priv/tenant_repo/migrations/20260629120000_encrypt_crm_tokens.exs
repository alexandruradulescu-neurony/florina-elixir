defmodule Florina.TenantRepo.Migrations.EncryptCrmTokens do
  use Ecto.Migration

  # Store CRM API tokens encrypted at rest (Cloak AES-GCM-256, ciphertext as
  # bytea) like the OAuth credentials, instead of plaintext :string. Pre-launch,
  # so we drop and re-add rather than re-encrypt in place — any plaintext value
  # is discarded and the token is re-entered via the settings UI. The domain is
  # not a secret and is left as plaintext.
  def up do
    alter table(:voice_globalsettings) do
      remove :pipedrive_api_token
      remove :hubspot_api_token
    end

    alter table(:voice_globalsettings) do
      add :pipedrive_api_token, :binary
      add :hubspot_api_token, :binary
    end
  end

  def down do
    alter table(:voice_globalsettings) do
      remove :pipedrive_api_token
      remove :hubspot_api_token
    end

    alter table(:voice_globalsettings) do
      add :pipedrive_api_token, :string
      add :hubspot_api_token, :string
    end
  end
end
