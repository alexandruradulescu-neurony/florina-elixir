defmodule Mix.Tasks.Florina.Tenants.Setup do
  @shortdoc "Provision local demo tenants (acme, globex), each with its own database"
  @moduledoc @shortdoc
  use Mix.Task
  alias Florina.Tenants.{ConnectionManager, Marker, Provisioner}

  @demo [
    {"acme", "Acme Corp", "florina_tenant_acme_dev"},
    {"globex", "Globex Inc", "florina_tenant_globex_dev"}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    for {slug, name, db} <- @demo do
      {:ok, _} = Provisioner.provision(%{slug: slug, name: name, database: db})
      {:ok, pid} = ConnectionManager.ensure_started(slug)
      Florina.TenantRepo.put_dynamic_repo(pid)
      Florina.TenantRepo.delete_all(Marker)
      Florina.TenantRepo.insert!(%Marker{label: "#{slug}-secret"})
      Mix.shell().info("provisioned #{slug} -> #{db}")
    end
  end
end
