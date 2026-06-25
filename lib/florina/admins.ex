defmodule Florina.Admins do
  @moduledoc """
  Context for control-plane admin (operator) accounts.
  All operations use `Florina.Repo` — never a per-tenant repo.
  """
  alias Florina.Repo
  alias Florina.Admins.Admin

  @doc "Fetch an admin by primary key. Returns nil if not found."
  def get_admin(id), do: Repo.get(Admin, id)

  @doc "Fetch an admin by email (case-insensitive). Returns nil if not found."
  def get_admin_by_email(email) when is_binary(email) do
    Repo.get_by(Admin, email: String.downcase(email))
  end

  @doc "Create a new admin. Returns {:ok, admin} or {:error, changeset}."
  def create_admin(attrs) do
    %Admin{}
    |> Admin.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Authenticate an admin by email + plain-text password.

  Returns `{:ok, admin}` on success, `{:error, :invalid}` otherwise.
  Always calls a bcrypt verification (either real or dummy) to prevent
  timing-based user-enumeration attacks.
  """
  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    admin = get_admin_by_email(email)

    cond do
      admin == nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid}

      Bcrypt.verify_pass(password, admin.hashed_password) ->
        {:ok, admin}

      true ->
        {:error, :invalid}
    end
  end

  @doc """
  Returns the total count of admin records.
  Used by the env-var seed guard to check whether any admin already exists.
  """
  def count do
    Repo.aggregate(Admin, :count, :id)
  end

  @doc """
  If `ADMIN_EMAIL` and `ADMIN_PASSWORD` environment variables are both set
  and no admin row exists yet, creates the first operator account automatically.

  Called once from `Florina.Application.start/2` after the supervision tree
  starts. Swallows all errors (table missing in fresh deploys, duplicate key
  on restart) so it never prevents the app from booting.
  """
  def ensure_seed_from_env do
    email = System.get_env("ADMIN_EMAIL")
    password = System.get_env("ADMIN_PASSWORD")

    if is_binary(email) and is_binary(password) and email != "" and password != "" do
      try do
        if count() == 0 do
          case create_admin(%{email: email, password: password}) do
            {:ok, admin} ->
              require Logger
              Logger.info("[Admins] Seeded operator admin from env: #{admin.email}")

            {:error, changeset} ->
              require Logger
              Logger.warning("[Admins] Env seed failed: #{inspect(changeset.errors)}")
          end
        end
      rescue
        e ->
          require Logger
          Logger.warning("[Admins] Env seed skipped (table may not exist yet): #{inspect(e)}")
      end
    end

    :ok
  end
end
