defmodule Mix.Tasks.Florina.Tenants.Setup do
  @shortdoc "Provision local demo tenants (acme, globex), each in its own Postgres schema"
  @moduledoc @shortdoc
  use Mix.Task
  alias Florina.Tenants
  alias Florina.Tenants.{Marker, Provisioner}

  @demo [
    {"acme", "Acme Corp"},
    {"globex", "Globex Inc"}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    for {slug, name} <- @demo do
      {:ok, tenant} = Provisioner.provision(%{slug: slug, name: name})

      Tenants.with_prefix(tenant, fn ->
        Florina.TenantRepo.delete_all(Marker)
        Florina.TenantRepo.insert!(%Marker{label: "#{slug}-secret"})
      end)

      Mix.shell().info("provisioned #{slug} -> schema #{Tenants.schema_prefix(tenant)}")
    end
  end
end
