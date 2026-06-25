defmodule Florina.Calendar.GoogleOauthCredential do
  @moduledoc """
  Stores Google OAuth credentials for users to enable background calendar sync.

  `token`, `refresh_token`, and `client_secret` are stored as plain `:text`
  for now. They carry sensitive secrets and should be encrypted at rest.
  # TODO: encrypt at rest (Cloak) — token, refresh_token, client_secret fields.

  Table: `voice_googleoauthcredential`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_googleoauthcredential" do
    belongs_to :user, Florina.Accounts.User

    # TODO: encrypt at rest (Cloak)
    field :token, :string
    # TODO: encrypt at rest (Cloak)
    field :refresh_token, :string
    field :token_uri, :string, default: "https://oauth2.googleapis.com/token"
    field :client_id, :string
    # TODO: encrypt at rest (Cloak)
    field :client_secret, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime

    timestamps()
  end

  @required_fields [:user_id, :token, :refresh_token, :client_id, :client_secret]
  @optional_fields [:token_uri, :scopes, :expires_at]

  @doc "Changeset for creating/updating OAuth credentials."
  def changeset(cred, attrs) do
    cred
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:client_id, max: 255)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end
