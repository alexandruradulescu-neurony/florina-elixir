defmodule Florina.Tenants.BootMigrator do
  @moduledoc """
  One-shot supervised step that applies pending per-tenant migrations to every
  provisioned tenant on boot.

  Placed in the supervision tree AFTER the Vault + Repo + ConnectionManager but
  BEFORE Oban and the Endpoint, so migrations finish before any job runs or any
  request is served on an out-of-date schema. Runs only when
  `:migrate_tenants_on_boot` is set (prod).

  Fail-loud: a migration error raises out of `start_link/0`, which aborts
  application boot — and therefore the deploy — instead of being logged and
  swallowed while traffic is already being served. (The previous version spawned
  an async, best-effort `Task` after the Endpoint had already started.)
  """
  require Logger

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker, restart: :temporary}
  end

  @doc """
  Run pending tenant migrations synchronously, then return `:ignore` so no
  process lingers in the tree. Raising here aborts boot by design.
  """
  def start_link do
    if Application.get_env(:florina, :migrate_tenants_on_boot, false) do
      migrate_all!()
    end

    :ignore
  end

  defp migrate_all! do
    # Only fully-provisioned tenants (status == "active" AND active == true). A
    # tenant still in `provisioning` or marked `failed` may have a half-created or
    # absent database; migrating it could raise and — since this step is
    # fail-loud — abort the whole app boot. Those tenants get migrated when their
    # provisioning completes (Provisioner.provision runs the migrator).
    for tenant <- Florina.Tenants.list_active() do
      {:ok, pid} = Florina.Tenants.ConnectionManager.ensure_started(tenant.slug)
      Florina.Tenants.Migrator.migrate_one(pid)
      Logger.info("[boot] per-tenant migrations applied for #{tenant.slug}")
    end

    :ok
  end
end
