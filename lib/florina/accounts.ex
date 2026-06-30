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
  alias Florina.Strings

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

  @doc """
  Sales agents that are still ACTIVE (`is_sales_agent: true` AND `active: true`)
  — the operational selector for background work (calendar sync fan-out, dialing).
  Distinct from `list_agents/0`, which returns all sales agents (incl. deactivated)
  for management screens that must still show/filter disabled accounts.
  """
  def list_active_agents do
    User
    |> where(is_sales_agent: true, active: true)
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
  def get_user(id) when is_integer(id), do: TenantRepo.get(User, id)

  # `id` often arrives as a string straight from a LiveView event/URL param. Parse
  # it instead of handing a non-integer to the bigint PK lookup (which would raise
  # an Ecto cast error and crash the caller); a non-numeric id is simply "no user".
  def get_user(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> TenantRepo.get(User, n)
      _ -> nil
    end
  end

  def get_user(_), do: nil

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a user record.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def create_user(attrs \\ %{}) do
    # `role` isn't in the general cast allow-list (privilege boundary), but
    # creation is server-side (admin invite / SSO upsert / seeding), so set it
    # explicitly here when provided.
    %User{}
    |> User.changeset(attrs)
    |> put_role(attrs[:role] || attrs["role"])
    |> TenantRepo.insert()
  end

  defp put_role(changeset, role) when role in [:manager, :agent],
    do: Ecto.Changeset.put_change(changeset, :role, role)

  defp put_role(changeset, role) when role in ["manager", "agent"],
    do: Ecto.Changeset.put_change(changeset, :role, String.to_existing_atom(role))

  defp put_role(changeset, _), do: changeset

  @doc """
  Updates a user record.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> TenantRepo.update()
  end

  @doc """
  Update a user's editable PROFILE fields only — first name, phone, Pipedrive user
  id. Restricted to those keys so this manager-facing edit can never change role,
  active, email, or username (each has its own guarded path). A blank value clears
  the field. Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def update_profile(%User{} = user, params) when is_map(params) do
    attrs =
      params
      |> Map.take(["first_name", "phone_number", "pipedrive_user_id"])
      |> Map.new(fn {k, v} -> {k, Strings.blank_to_nil(v)} end)

    update_user(user, attrs)
  end

  @doc """
  Sets a user's permission role (`:manager` or `:agent`). Demoting the last active
  manager is refused atomically. Returns `{:ok, user}` | `{:error, :last_manager}`
  | `{:error, changeset}`.
  """
  def set_role(%User{} = user, role) when role in [:manager, :agent] do
    guard_last_manager(removes_manager?(user, role: role), fn ->
      user |> User.role_changeset(role) |> TenantRepo.update()
    end)
  end

  @doc """
  Activates or deactivates a user (deactivated users can't sign in). Deactivating
  the last active manager is refused atomically.
  """
  def set_active(%User{} = user, active) when is_boolean(active) do
    guard_last_manager(removes_manager?(user, active: active), fn ->
      user |> User.active_changeset(active) |> TenantRepo.update()
    end)
  end

  defp removes_manager?(%User{role: :manager, active: true}, role: :agent), do: true
  defp removes_manager?(%User{role: :manager, active: true}, active: false), do: true
  defp removes_manager?(_user, _change), do: false

  # When the change would drop a manager, run it inside a transaction that locks
  # the active-manager rows and re-counts, so two concurrent demotions/
  # deactivations can't race past the check and leave zero active managers.
  defp guard_last_manager(false, fun), do: fun.()

  defp guard_last_manager(true, fun) do
    TenantRepo.transaction(fn ->
      count =
        User
        |> where([u], u.role == :manager and u.active == true)
        |> lock("FOR UPDATE")
        |> TenantRepo.all()
        |> length()

      if count <= 1 do
        TenantRepo.rollback(:last_manager)
      else
        case fun.() do
          {:ok, updated} -> updated
          {:error, changeset} -> TenantRepo.rollback(changeset)
        end
      end
    end)
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
        |> Enum.reject(fn {_k, v} -> Strings.blank?(v) end)
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
end
