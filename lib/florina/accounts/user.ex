defmodule Florina.Accounts.User do
  @moduledoc """
  Sales agent user entity — port of Django's `voice.User` (custom AbstractUser).

  This is the *agent data record*, NOT an auth model. Login/auth is a
  separate slice. Fields kept: username, email, first_name, last_name,
  pipedrive_user_id, phone_number, is_sales_agent, default_methodology_id.
  Django auth fields (password, groups, permissions, etc.) are intentionally omitted.

  Table: `voice_user`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_user" do
    field :username, :string
    field :email, :string
    field :first_name, :string
    field :last_name, :string
    field :pipedrive_user_id, :integer
    field :phone_number, :string
    field :is_sales_agent, :boolean, default: false
    field :active, :boolean, default: true

    # FK to voice_methodology — added after methodology table exists (circular ref).
    # nil until methodology table created.
    belongs_to :default_methodology, Florina.Methodologies.Methodology

    timestamps()
  end

  @required_fields [:username]
  @optional_fields [
    :email,
    :first_name,
    :last_name,
    :pipedrive_user_id,
    :phone_number,
    :is_sales_agent,
    :active,
    :default_methodology_id
  ]

  @doc "Changeset for creating/updating a user agent record."
  def changeset(user, attrs) do
    user
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:username, max: 150)
    |> validate_length(:phone_number, max: 20)
    |> unique_constraint(:username)
  end
end
