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

    create unique_index(:oauth_credentials, [:provider, :purpose, :user_id, :email],
             name: :oauth_credentials_provider_purpose_user_email_index
           )
  end
end
