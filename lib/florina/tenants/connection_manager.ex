defmodule Florina.Tenants.ConnectionManager do
  @moduledoc """
  Starts, caches and reuses exactly one connection pool per tenant database.
  Returns the pid of a started `Florina.TenantRepo` instance; callers pin it
  with `Florina.TenantRepo.put_dynamic_repo/1`.
  """
  use GenServer
  alias Florina.Tenants

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Returns {:ok, pid} for a known tenant, or {:error, reason}."
  def ensure_started(slug), do: GenServer.call(__MODULE__, {:ensure, slug})

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:ensure, slug}, _from, state) do
    case state do
      %{^slug => pid} ->
        if Process.alive?(pid),
          do: {:reply, {:ok, pid}, state},
          else: start(slug, Map.delete(state, slug))

      _ ->
        start(slug, state)
    end
  end

  defp start(slug, state) do
    case Tenants.get_by_slug(slug) do
      nil ->
        {:reply, {:error, :unknown_tenant}, state}

      tenant ->
        case Florina.TenantRepo.start_link(connection_opts(tenant)) do
          {:ok, pid} -> {:reply, {:ok, pid}, Map.put(state, slug, pid)}
          {:error, {:already_started, pid}} -> {:reply, {:ok, pid}, Map.put(state, slug, pid)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # Reuse the control-plane DB's connection (local fields OR a production :url),
  # overriding only the database name (from the registry).
  defp connection_opts(tenant) do
    base = Application.get_env(:florina, Florina.Repo)
    pool_size = Application.get_env(:florina, :tenant_pool_size, 2)
    Florina.Tenants.ConnectionOpts.build(base, tenant.database, pool_size)
  end
end
