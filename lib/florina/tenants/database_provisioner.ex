defmodule Florina.Tenants.DatabaseProvisioner do
  @moduledoc """
  Pluggable backend for **physically creating/dropping the database that backs a
  tenant**. The core app (`Florina.Tenants.Provisioner`, the admin UI) depends
  only on this behaviour — never on a specific host or provider.

  Swap environments by changing one config line:

      config :florina, :database_provisioner, Florina.Tenants.DatabaseProvisioner.SamePostgres

  Today the default creates the database on the same Postgres the app is pointed
  at (Railway). To move to AWS RDS, a separate-instance-per-tenant model, or a
  provisioning API later, write a new module implementing this behaviour and
  point the config at it — no core changes.
  """

  @callback create_database(database :: String.t()) :: :ok | {:error, term()}
  @callback drop_database(database :: String.t()) :: :ok | {:error, term()}

  @default Florina.Tenants.DatabaseProvisioner.SamePostgres

  @doc "The configured provisioning backend."
  def impl, do: Application.get_env(:florina, :database_provisioner, @default)

  @doc "Create the physical database for a tenant via the configured backend."
  def create_database(database), do: impl().create_database(database)

  @doc "Drop the physical database for a tenant via the configured backend."
  def drop_database(database), do: impl().drop_database(database)
end
