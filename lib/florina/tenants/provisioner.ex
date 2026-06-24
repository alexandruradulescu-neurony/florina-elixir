defmodule Florina.Tenants.Provisioner do
  @moduledoc """
  Operator-driven onboarding for a tenant: create the database, register it in
  the control plane, and migrate it. Idempotent — safe to run repeatedly.
  """
  alias Florina.Tenants
  alias Florina.Tenants.{ConnectionManager, Migrator}

  def provision(%{slug: slug, name: name, database: database}) do
    :ok = create_database(database)
    {:ok, _} = Tenants.register(%{slug: slug, name: name, database: database})
    {:ok, pid} = ConnectionManager.ensure_started(slug)
    Migrator.migrate_one(pid)
    {:ok, Tenants.get_by_slug(slug)}
  end

  defp create_database(database) do
    opts =
      Application.get_env(:florina, Florina.Repo)
      |> Keyword.take([:username, :password, :hostname, :port])
      |> Keyword.put(:database, database)

    case Ecto.Adapters.Postgres.storage_up(opts) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "could not create tenant database #{database}: #{inspect(reason)}"
    end
  end
end
