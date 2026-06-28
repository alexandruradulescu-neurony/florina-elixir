defmodule Florina.Repo.Migrations.DropDatabaseFromTenants do
  use Ecto.Migration

  # The `database` column is a vestige of the old database-per-tenant design.
  # Runtime routing is purely by the `tenant_<id>` Postgres schema prefix, so the
  # column is unused. Drop it. (Pre-launch: no tenant data to preserve.)
  def change do
    alter table(:tenants) do
      remove :database, :string
    end
  end
end
