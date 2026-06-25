defmodule Mix.Tasks.Florina.Tenants.Setup do
  @shortdoc "Provision local demo tenants (acme, globex), each in its own Postgres schema"
  @moduledoc @shortdoc
  use Mix.Task
  alias Florina.Tenants
  alias Florina.Tenants.{Marker, Provisioner}

  # database name is incidental in the schema-per-tenant model (kept only because
  # the registry column still exists); the real isolation unit is the schema.
  @demo [
    {"acme", "Acme Corp", "florina_tenant_acme_dev"},
    {"globex", "Globex Inc", "florina_tenant_globex_dev"}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    for {slug, name, db} <- @demo do
      {:ok, tenant} = Provisioner.provision(%{slug: slug, name: name, database: db})

      Tenants.with_prefix(tenant, fn ->
        Florina.TenantRepo.delete_all(Marker)
        Florina.TenantRepo.insert!(%Marker{label: "#{slug}-secret"})
      end)

      Mix.shell().info("provisioned #{slug} -> schema #{Tenants.schema_prefix(tenant)}")
    end
  end
end
