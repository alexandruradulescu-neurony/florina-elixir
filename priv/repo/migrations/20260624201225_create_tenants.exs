defmodule Florina.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :database, :string, null: false
      add :active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:tenants, [:slug])
  end
end
