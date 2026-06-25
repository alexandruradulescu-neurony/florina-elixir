defmodule Florina.Repo.Migrations.AddAllowedEmailDomainsToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :allowed_email_domains, {:array, :string}, null: false, default: []
    end
  end
end
