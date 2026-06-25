defmodule Florina.Accounts do
  @moduledoc """
  Context for sales-agent user records.

  "Agents" are users with `is_sales_agent: true`. Login/auth is out of scope
  for this slice — these are *data records* only.

  All queries hit `TenantRepo` (the pinned, per-tenant connection).
  """

  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.Accounts.User

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns all sales agents (`is_sales_agent: true`), ordered by username.

  Mirrors Django's `get_sales_agents()` selector.
  """
  def list_agents do
    User
    |> where(is_sales_agent: true)
    |> order_by(:username)
    |> TenantRepo.all()
  end

  @doc "Returns all users (agents and non-agents), ordered by username."
  def list_users do
    User
    |> order_by(:username)
    |> TenantRepo.all()
  end

  @doc "Gets a user by ID. Raises `Ecto.NoResultsError` if not found."
  def get_user!(id) do
    TenantRepo.get!(User, id)
  end

  @doc "Gets a user by ID. Returns `nil` if not found."
  def get_user(id) do
    TenantRepo.get(User, id)
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a user record.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> TenantRepo.insert()
  end

  @doc """
  Updates a user record.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> TenantRepo.update()
  end

  # ---------------------------------------------------------------------------
  # Identity helpers
  # ---------------------------------------------------------------------------

  @doc "Find a user by email (case-insensitive). Returns nil if not found."
  def get_user_by_email(email) when is_binary(email) do
    down = String.downcase(email)
    User |> where([u], fragment("lower(?)", u.email) == ^down) |> TenantRepo.one()
  end

  @doc """
  Create-or-find a sales agent from a verified OAuth identity.
  Returns `{:ok, user}`, or `{:error, :inactive}` if a matching agent is deactivated.
  """
  def upsert_agent_from_identity(%{email: email} = identity) when is_binary(email) do
    down = String.downcase(email)

    case get_user_by_email(down) do
      nil ->
        create_user(%{
          username: down,
          email: down,
          first_name: identity[:name],
          is_sales_agent: true,
          active: true
        })

      %User{active: false} ->
        {:error, :inactive}

      %User{} = user ->
        update_user(user, %{is_sales_agent: true})
    end
  end
end
