defmodule Florina.Admins.Admin do
  @moduledoc "Control-plane admin (operator) account."
  use Ecto.Schema
  import Ecto.Changeset

  schema "admins" do
    field :email, :string
    field :hashed_password, :string
    field :password, :string, virtual: true

    timestamps()
  end

  @doc """
  Changeset for creating a new admin.
  Validates email format, enforces minimum password length,
  and stores only the bcrypt hash — never the plain-text password.
  """
  def registration_changeset(admin \\ %__MODULE__{}, attrs) do
    admin
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> update_change(:email, &String.downcase/1)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> unique_constraint(:email)
    |> put_hashed_password()
  end

  defp put_hashed_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :hashed_password, Bcrypt.hash_pwd_salt(password))
    end
  end
end
