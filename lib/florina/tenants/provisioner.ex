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
    :ok = Florina.CentralConfig.seed_tenant(slug)
    {:ok, Tenants.get_by_slug(slug)}
  end

  defp create_database(database) do
    case Florina.Tenants.DatabaseProvisioner.create_database(database) do
      :ok -> :ok
      {:error, reason} -> raise "could not create tenant database #{database}: #{inspect(reason)}"
    end
  end
end
