defmodule Florina.Tenants.DatabaseProvisioner.SamePostgres do
  @moduledoc """
  Default `DatabaseProvisioner`: creates the tenant database on the SAME Postgres
  server the app already connects to. The connection is derived from the app's
  `Florina.Repo` config via `Florina.Tenants.ConnectionOpts.server_params/0`, so
  it works in dev (discrete settings) AND in production (a `DATABASE_URL`) —
  this is the fix for provisioning failing in prod, where the discrete fields are
  absent.

  Requires the app's Postgres role to have `CREATEDB` (Railway's managed role
  does). Not tied to Railway: point the app at any Postgres and this still works.
  """
  @behaviour Florina.Tenants.DatabaseProvisioner

  alias Florina.Tenants.ConnectionOpts

  @impl true
  def create_database(database) do
    database |> opts() |> Ecto.Adapters.Postgres.storage_up() |> normalize(:already_up)
  end

  @impl true
  def drop_database(database) do
    database |> opts() |> Ecto.Adapters.Postgres.storage_down() |> normalize(:already_down)
  end

  # storage_up/down connect to the `:maintenance_database` (an existing DB) to
  # issue CREATE/DROP DATABASE for `:database`. We use the app's own database as
  # the maintenance DB — it always exists and the app's role can reach it.
  defp opts(database) do
    ConnectionOpts.server_params()
    |> Keyword.put(:database, database)
    |> Keyword.put(:maintenance_database, ConnectionOpts.app_database())
  end

  defp normalize(:ok, _benign), do: :ok
  defp normalize({:error, benign}, benign), do: :ok
  defp normalize(other, _benign), do: other
end
