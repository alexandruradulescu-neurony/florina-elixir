defmodule Florina.Workers.ProvisionTenant do
  @moduledoc """
  Oban worker that provisions a tenant database in the background.

  Args: %{"slug" => slug, "name" => name, "database" => database}

  On success: sets tenant status to "active".
  On error: sets tenant status to "failed" and logs the error.
  Provision is idempotent — safe to retry.

  Note: Provisioner.provision/1 raises on hard failures (e.g. PG storage error),
  so we rescue RuntimeError here and translate to {:error, reason}.
  """
  use Oban.Worker, queue: :provisioning, max_attempts: 3

  require Logger

  alias Florina.Tenants
  alias Florina.Tenants.Provisioner

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"slug" => slug, "name" => name, "database" => database}}) do
    Logger.info("[ProvisionTenant] starting provisioning for tenant=#{slug} db=#{database}")

    {:ok, _tenant} = Provisioner.provision(%{slug: slug, name: name, database: database})
    Logger.info("[ProvisionTenant] provisioning succeeded for tenant=#{slug}")
    Tenants.set_status(slug, "active")
    :ok
  rescue
    e ->
      reason = Exception.message(e)
      Logger.error("[ProvisionTenant] provisioning failed for tenant=#{slug}: #{reason}")
      Tenants.set_status(slug, "failed")
      {:error, reason}
  end
end
