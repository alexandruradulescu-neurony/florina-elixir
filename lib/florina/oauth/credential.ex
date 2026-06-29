defmodule Florina.OAuth.Credential do
  @moduledoc """
  Unified OAuth connection record (per tenant) — one row per connected account.
  Replaces the Google-only `voice_googleoauthcredential`. Tagged by `provider`
  (:google | :microsoft) and `purpose` (:agent_calendar | :florina_mailbox).
  `access_token`, `refresh_token`, `client_secret` are Cloak-encrypted (bytea).

  Table: `oauth_credentials`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  @providers [:google, :microsoft]
  @purposes [:agent_calendar, :florina_mailbox]

  schema "oauth_credentials" do
    belongs_to :user, Florina.Accounts.User
    field :provider, Ecto.Enum, values: @providers
    field :purpose, Ecto.Enum, values: @purposes, default: :agent_calendar
    field :email, :string
    field :access_token, Florina.Encrypted.Binary, redact: true
    field :refresh_token, Florina.Encrypted.Binary, redact: true
    field :client_id, :string
    field :client_secret, Florina.Encrypted.Binary, redact: true
    field :token_uri, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    timestamps()
  end

  @required [:provider, :purpose, :access_token]
  @optional [
    # user_id is nullable: future florina_mailbox credentials have no agent user
    :user_id,
    :email,
    :refresh_token,
    :client_id,
    :client_secret,
    :token_uri,
    :scopes,
    :expires_at
  ]

  def changeset(cred, attrs) do
    cred
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:provider, :purpose, :user_id],
      name: :oauth_credentials_provider_purpose_user_index
    )
  end
end
