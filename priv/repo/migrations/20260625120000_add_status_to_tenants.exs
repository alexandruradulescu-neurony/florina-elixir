defmodule Florina.Repo.Migrations.AddStatusToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :status, :string, null: false, default: "active"
    end
  end
end
