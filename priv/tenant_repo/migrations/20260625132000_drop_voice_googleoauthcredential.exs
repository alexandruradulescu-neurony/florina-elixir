defmodule Florina.Repo.Migrations.DropVoiceGoogleoauthcredential do
  use Ecto.Migration

  def up do
    drop_if_exists table(:voice_googleoauthcredential)
  end

  def down do
    create table(:voice_googleoauthcredential) do
      add :user_id, references(:voice_user, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :refresh_token, :binary, null: false
      add :token_uri, :string, default: "https://oauth2.googleapis.com/token"
      add :client_id, :string, null: false
      add :client_secret, :binary, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_googleoauthcredential, [:user_id])
  end
end
