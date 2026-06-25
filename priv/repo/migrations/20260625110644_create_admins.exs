defmodule Florina.Repo.Migrations.CreateAdmins do
  use Ecto.Migration

  def change do
    create table(:admins) do
      add :email, :string, null: false
      add :hashed_password, :string, null: false

      timestamps()
    end

    create unique_index(:admins, [:email])
  end
end
