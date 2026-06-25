defmodule Florina.Accounts do
  @moduledoc """
  Context for sales-agent user records.

  "Agents" are users with `is_sales_agent: true`. Login/auth is out of scope
  for this slice — these are *data records* only.

  All queries hit `TenantRepo` (the pinned, per-tenant connection).
  """

  import Ecto.Query, only: [order_by: 2, where: 2]
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
end
