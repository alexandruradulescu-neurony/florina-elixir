defmodule Florina.TenantRepo.Migrations.CreateTenantMarkers do
  use Ecto.Migration

  def change do
    create table(:tenant_markers) do
      add :label, :string, null: false
      timestamps(type: :utc_datetime)
    end
  end
end
