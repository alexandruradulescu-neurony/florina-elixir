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

    # Permission role (independent of is_sales_agent, which means "is dialable").
    # Managers see the whole tenant; agents see only their own data. See Florina.Authz.
    field :role, Ecto.Enum, values: [:manager, :agent], default: :agent

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

  @doc """
  Changeset for creating/updating a user agent record.

  `:role` is deliberately NOT in the cast allow-list — the permission role is a
  privilege boundary and must only be set via `role_changeset/2` from authorized
  server code (`Accounts.set_role/2`), never mass-assigned from form params.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:username, max: 150)
    |> validate_length(:phone_number, max: 20)
    # first_name/last_name/email are written from provider (SSO) data on sign-in;
    # truncate to the column limits so an exotic long name can't crash first login.
    |> truncate(:email, 254)
    |> truncate(:first_name, 150)
    |> truncate(:last_name, 150)
    |> unique_constraint(:username)
    |> unique_constraint(:email, name: :voice_user_email_lower_index)
  end

  defp truncate(changeset, field, max) do
    case get_change(changeset, field) do
      value when is_binary(value) and byte_size(value) > max ->
        put_change(changeset, field, String.slice(value, 0, max))

      _ ->
        changeset
    end
  end

  @doc """
  Human-friendly label for a user: full name (first + last) if present, else the
  email, else the username, else `nil`. The single source of truth for the
  "who is this agent" label shown across the manager/calendar screens. Accepts any
  map with the relevant keys so it also works on association-preloaded structs.
  """
  def display_name(%{first_name: f, last_name: l} = u) do
    case [f, l] |> Enum.reject(&blank?/1) |> Enum.join(" ") do
      "" -> email_or_username(u)
      name -> name
    end
  end

  def display_name(%{} = u), do: email_or_username(u)
  def display_name(_), do: nil

  # Map.get (not `u[...]`) so this works on %User{} structs, which don't implement
  # the Access behaviour.
  defp email_or_username(u) do
    cond do
      present?(Map.get(u, :email)) -> Map.get(u, :email)
      present?(Map.get(u, :username)) -> Map.get(u, :username)
      true -> nil
    end
  end

  defp present?(v), do: is_binary(v) and v != ""

  @doc """
  Short first-person greeting name for voice: the first name if present, else the
  username. Used where Florina addresses the caller by name.
  """
  def greeting_name(%{first_name: f, username: un}) do
    if is_binary(f) and f != "", do: f, else: un
  end

  defp blank?(v), do: v in [nil, ""]

  @doc "Privilege-role change — server-only, not from user params."
  def role_changeset(user, role) when role in [:manager, :agent], do: change(user, role: role)

  @doc "Active-flag change — server-only."
  def active_changeset(user, active) when is_boolean(active), do: change(user, active: active)
end
