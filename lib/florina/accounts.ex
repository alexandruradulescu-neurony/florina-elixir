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

  @doc "Sets a user's permission role (`:manager` or `:agent`)."
  def set_role(%User{} = user, role) when role in [:manager, :agent] do
    update_user(user, %{role: role})
  end

  @doc "Activates or deactivates a user (deactivated users can't sign in)."
  def set_active(%User{} = user, active) when is_boolean(active) do
    update_user(user, %{active: active})
  end

  @doc "Number of active managers in the current tenant (guards last-manager removal)."
  def manager_count do
    User
    |> where(role: :manager, active: true)
    |> TenantRepo.aggregate(:count)
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

  @doc """
  Pre-create ("invite") an agent by email so they appear in the tenant before
  their first SSO sign-in. On that first Google/Microsoft login,
  `upsert_agent_from_identity/1` matches by email and adopts this row — keeping
  the role set here (so an invited manager logs in as a manager).

  `params` is a string-keyed map: `"email"` (required) plus optional `"role"`,
  `"first_name"`, `"phone_number"`, `"pipedrive_user_id"`. Blank optionals are
  dropped. Returns `{:ok, user}`, `{:error, :email_required}`,
  `{:error, :already_exists}`, or `{:error, changeset}`.
  """
  def invite_agent(params) when is_map(params) do
    email = params |> Map.get("email", "") |> to_string() |> String.trim() |> String.downcase()

    cond do
      email == "" ->
        {:error, :email_required}

      get_user_by_email(email) ->
        {:error, :already_exists}

      true ->
        params
        |> Map.take(["role", "first_name", "phone_number", "pipedrive_user_id"])
        |> Enum.reject(fn {_k, v} -> blank?(v) end)
        |> Map.new()
        |> Map.merge(%{
          "username" => email,
          "email" => email,
          "is_sales_agent" => true,
          "active" => true
        })
        |> create_user()
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
