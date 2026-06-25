defmodule Florina.Repo.Migrations.CreateOauthCredentials do
  use Ecto.Migration

  def change do
    create table(:oauth_credentials) do
      add :user_id, references(:voice_user, on_delete: :delete_all)
      add :provider, :string, null: false
      add :purpose, :string, null: false, default: "agent_calendar"
      add :email, :string, size: 254
      add :access_token, :binary, null: false
      add :refresh_token, :binary
      add :client_id, :string, size: 255
      add :client_secret, :binary
      add :token_uri, :string, size: 255
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:oauth_credentials, [:user_id])

    # One calendar credential per (user, provider). `email` is intentionally NOT
    # part of the key — it's the agent's incidental address, and the upsert keys on
    # user+provider+purpose. (Phase-2 florina_mailbox rows have user_id = NULL and
    # will get their own partial unique index then.)
    create unique_index(:oauth_credentials, [:provider, :purpose, :user_id],
             name: :oauth_credentials_provider_purpose_user_index
           )
  end
end
