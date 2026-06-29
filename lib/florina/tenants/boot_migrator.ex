defmodule Florina.Tenants.BootMigrator do
  @moduledoc """
  One-shot supervised step that applies pending per-tenant migrations to every
  provisioned tenant on boot.

  Placed in the supervision tree AFTER the Vault + Repo but BEFORE Oban and the
  Endpoint, so migrations finish before any job runs or any request is served on
  an out-of-date schema. Runs only when `:migrate_tenants_on_boot` is set (prod).

  Schema-per-tenant: each tenant's schema (`tenant_<id>`) is ensured to exist and
  migrated on the single shared `Florina.Repo`.

  Per-tenant fault isolation: a single tenant's migration failure does NOT abort
  the whole deploy (which would take every other tenant down with it). The failing
  tenant is marked `failed` — so `ResolveTenant`/`accessible?` immediately stop
  serving it on a half-migrated schema (fail-closed for THAT tenant only) — logged
  at error, and boot continues for the rest. Recover a failed tenant with
  `Tenants.activate/1`, which re-migrates before re-serving. (Control-plane
  migrations are separate, run by `Release.migrate` in the pre-deploy step, and
  still fail the deploy loudly.)
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
    # absent schema; migrating it could raise and — since this step is fail-loud —
    # abort the whole app boot. Those tenants get migrated when their provisioning
    # completes (Provisioner.provision runs the migrator).
    for tenant <- Florina.Tenants.list_active() do
      prefix = Florina.Tenants.schema_prefix(tenant)

      try do
        Florina.Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))
        Florina.Tenants.Migrator.migrate_one(tenant)
        Logger.info("[boot] per-tenant migrations applied for #{tenant.slug} (#{prefix})")
      rescue
        e ->
          # Isolate the blast radius: mark only THIS tenant failed (so it isn't
          # served on a half-migrated schema) and keep going for the others.
          Logger.error(
            "[boot] per-tenant migration FAILED for #{tenant.slug} (#{prefix}): " <>
              Exception.message(e) <> " — marking tenant failed, continuing"
          )

          Florina.Tenants.set_status(tenant.slug, "failed")
      end
    end

    :ok
  end
end
