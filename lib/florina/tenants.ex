defmodule Florina.Tenants do
  @moduledoc """
  Control-plane registry of tenants. Each tenant's data lives in its own Postgres
  **schema** (`tenant_<id>`) on the single shared database; this module owns the
  registry rows and the schema-prefix helpers every chokepoint pins from.
  """
  import Ecto.Query, only: [from: 2]
  alias Florina.Repo
  alias Florina.Tenants.Tenant

  @doc """
  The Postgres schema name for a tenant: `"tenant_<id>"`. Derived from the
  tenant's immutable id (never the mutable slug), so a slug rename never moves a
  tenant's data.
  """
  def schema_prefix(%Tenant{id: id}) when is_integer(id), do: "tenant_#{id}"

  @doc "PubSub topic carrying tenant-lifecycle events (e.g. disable) for a slug."
  def pubsub_topic(slug) when is_binary(slug), do: "tenant:" <> slug

  @doc "Run `fun` with the tenant's schema prefix pinned on the current process."
  def with_prefix(%Tenant{} = tenant, fun) when is_function(fun, 0) do
    prev_prefix = Process.get(:tenant_prefix)
    prev_repo = Process.get(:tenant_repo)
    Process.put(:tenant_prefix, schema_prefix(tenant))
    # with_prefix runs in web/CLI/provisioning contexts → use the default (web)
    # pool. Clear :tenant_repo so the two per-process states stay in lockstep and
    # this block can't inherit a caller's jobs-pool pin; both are restored after.
    Process.delete(:tenant_repo)

    try do
      fun.()
    after
      restore_pdict(:tenant_prefix, prev_prefix)
      restore_pdict(:tenant_repo, prev_repo)
    end
  end

  defp restore_pdict(key, nil), do: Process.delete(key)
  defp restore_pdict(key, value), do: Process.put(key, value)

  def list, do: Repo.all(from t in Tenant, order_by: t.slug)

  @doc "Returns only tenants that are fully provisioned: status == \"active\" AND active == true."
  def list_active,
    do:
      Repo.all(
        from t in Tenant, where: t.status == "active" and t.active == true, order_by: t.slug
      )

  # Slugs are stored normalized (lowercase, see Tenant.changeset); look up
  # case-insensitively so a differently-cased URL/host resolves to the same tenant
  # instead of failing closed by accident.
  def get_by_slug(slug) when is_binary(slug), do: Repo.get_by(Tenant, slug: String.downcase(slug))
  def get_by_slug(_), do: nil

  @doc """
  Find the active tenant that owns an email domain (its `allowed_email_domains`
  contains `domain`, case-insensitively). Used to auto-detect a signer-in's
  workspace from their verified email — the same domain→tenant match the sign-in
  gate applies. Returns the `%Tenant{}` or `nil` (none, or domain not configured).

  Matching is done in Elixir over the (small) active-tenant set so it stays
  consistent with the gate's case handling; a domain is assumed to belong to one
  workspace — if two claimed it, the first by slug wins.
  """
  def get_by_email_domain(domain) when is_binary(domain) do
    d = domain |> String.trim() |> String.downcase()

    if d == "" do
      nil
    else
      Enum.find(list_active(), fn t ->
        d in Enum.map(t.allowed_email_domains || [], &String.downcase/1)
      end)
    end
  end

  def get_by_email_domain(_), do: nil

  @doc """
  True only if the tenant exists, is enabled (`active: true`) AND fully
  provisioned (`status: "active"`). This is the gate for serving any request or
  running any operational background job for a tenant — a `provisioning`/`failed`
  tenant is never reachable even if `active` happens to be true. (Provisioning
  itself uses `Workers.Tenant.pin!/1` directly, so it is exempt.)
  """
  def accessible?(slug) when is_binary(slug) do
    case get_by_slug(slug) do
      %Tenant{active: true, status: "active"} -> true
      _ -> false
    end
  end

  def accessible?(_), do: false

  @doc "Insert a tenant. Idempotent on slug: an existing slug is left unchanged."
  def register(attrs) do
    slug = attrs[:slug] || attrs["slug"]

    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :slug)
    |> case do
      {:ok, _} -> {:ok, get_by_slug(slug)}
      {:error, _} = err -> err
    end
  end

  @doc "Set the status of a tenant (provisioning | active | failed)."
  def set_status(slug, status)
      when is_binary(slug) and status in ~w(provisioning active failed) do
    case get_by_slug(slug) do
      nil ->
        {:error, :not_found}

      tenant ->
        result = tenant |> Tenant.changeset(%{status: status}) |> Repo.update()
        # Any move OFF "active" (failed/provisioning) disconnects live sessions.
        if match?({:ok, _}, result) and status != "active", do: broadcast_disabled(tenant.slug)
        result
    end
  end

  @doc "Toggle the active flag on a tenant."
  def set_active(slug, active) when is_binary(slug) and is_boolean(active) do
    case get_by_slug(slug) do
      nil ->
        {:error, :not_found}

      tenant ->
        result = tenant |> Tenant.changeset(%{active: active}) |> Repo.update()
        if match?({:ok, _}, result) and active == false, do: broadcast_disabled(tenant.slug)
        result
    end
  end

  # Tell every connected LiveView for this tenant to disconnect (TenantHook
  # subscribes to pubsub_topic/1). Safe no-op when there are no subscribers
  # (e.g. BootMigrator marking a tenant failed during startup).
  defp broadcast_disabled(slug) do
    Phoenix.PubSub.broadcast(Florina.PubSub, pubsub_topic(slug), {:tenant_disabled, slug})
  end

  @doc """
  Activate a tenant, first ensuring its schema exists and any pending per-tenant
  migrations are applied — BEFORE it can serve traffic. Boot migrations skip
  inactive tenants, so a tenant that was deactivated across a deploy (which added
  migrations) would otherwise be reactivated onto a stale schema. Fail-loud: if
  migration raises, the tenant is left inactive. Migration runs only when
  `:migrate_tenants_on_boot` is set (prod); dev/test just flip the flag, matching
  `BootMigrator`.
  """
  def activate(slug) when is_binary(slug) do
    case get_by_slug(slug) do
      nil ->
        {:error, :not_found}

      tenant ->
        if Application.get_env(:florina, :migrate_tenants_on_boot, false) do
          prefix = schema_prefix(tenant)
          Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"))
          Florina.Tenants.Migrator.migrate_one(tenant)
        end

        set_active(slug, true)
    end
  end

  @doc "Replace a tenant's allowed email-domain list."
  def set_allowed_domains(slug, domains) when is_list(domains) do
    case get_by_slug(slug) do
      nil -> {:error, :not_found}
      tenant -> tenant |> Tenant.changeset(%{allowed_email_domains: domains}) |> Repo.update()
    end
  end
end
