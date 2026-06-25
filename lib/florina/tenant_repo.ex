defmodule Florina.TenantRepo do
  @moduledoc """
  Fail-closed proxy over the single `Florina.Repo` for all per-tenant data.

  There is exactly **one** database and **one** connection pool (`Florina.Repo`).
  Tenant data is isolated by Postgres **schema**, one schema per tenant named
  `tenant_<id>`. This module is NOT an `Ecto.Repo` — it is a thin shim that:

    1. reads the current tenant's schema from `Process.get(:tenant_prefix)`,
    2. **raises** if no prefix is in scope (never silently falls back to the
       `public`/control-plane schema — that would leak control-plane data into a
       tenant context, or vice-versa), and
    3. forwards the call to `Florina.Repo` with `prefix:` injected.

  The current prefix is pinned per-process by the request/job chokepoints
  (`ResolveTenant`, `TenantHook`, `Workers.Tenant`) with
  `Process.put(:tenant_prefix, "tenant_<id>")`.

  Deliberately absent from `:ecto_repos`, so `mix ecto.migrate` and the release
  migrator only ever touch `Florina.Repo` (the control plane). Tenant schemas are
  migrated explicitly via `Florina.Tenants.Migrator` with the schema prefix.
  """

  @doc "The schema prefix for the current process, or raise if none is in scope."
  def prefix! do
    Process.get(:tenant_prefix) ||
      raise "Florina.TenantRepo called with no tenant prefix in scope"
  end

  defp put(opts), do: Keyword.put(opts, :prefix, prefix!())

  # --- reads -----------------------------------------------------------------
  def all(queryable, opts \\ []), do: Florina.Repo.all(queryable, put(opts))
  def get(queryable, id, opts \\ []), do: Florina.Repo.get(queryable, id, put(opts))
  def get!(queryable, id, opts \\ []), do: Florina.Repo.get!(queryable, id, put(opts))

  def get_by(queryable, clauses, opts \\ []),
    do: Florina.Repo.get_by(queryable, clauses, put(opts))

  def get_by!(queryable, clauses, opts \\ []),
    do: Florina.Repo.get_by!(queryable, clauses, put(opts))

  def one(queryable, opts \\ []), do: Florina.Repo.one(queryable, put(opts))
  def one!(queryable, opts \\ []), do: Florina.Repo.one!(queryable, put(opts))
  def exists?(queryable, opts \\ []), do: Florina.Repo.exists?(queryable, put(opts))

  @doc """
  `aggregate(queryable, aggregate, opts)` (e.g. `:count`) and the field form
  `aggregate(queryable, aggregate, field, opts)`.
  """
  def aggregate(queryable, aggregate, opts \\ [])
      when is_atom(aggregate) and is_list(opts),
      do: Florina.Repo.aggregate(queryable, aggregate, put(opts))

  def aggregate(queryable, aggregate, field, opts)
      when is_atom(aggregate) and is_atom(field),
      do: Florina.Repo.aggregate(queryable, aggregate, field, put(opts))

  # --- writes ----------------------------------------------------------------
  def insert(struct_or_changeset, opts \\ []),
    do: Florina.Repo.insert(struct_or_changeset, put(opts))

  def insert!(struct_or_changeset, opts \\ []),
    do: Florina.Repo.insert!(struct_or_changeset, put(opts))

  def update(changeset, opts \\ []), do: Florina.Repo.update(changeset, put(opts))
  def update!(changeset, opts \\ []), do: Florina.Repo.update!(changeset, put(opts))

  def delete(struct_or_changeset, opts \\ []),
    do: Florina.Repo.delete(struct_or_changeset, put(opts))

  def delete!(struct_or_changeset, opts \\ []),
    do: Florina.Repo.delete!(struct_or_changeset, put(opts))

  def insert_or_update(changeset, opts \\ []),
    do: Florina.Repo.insert_or_update(changeset, put(opts))

  def insert_all(schema_or_source, entries, opts \\ []),
    do: Florina.Repo.insert_all(schema_or_source, entries, put(opts))

  def update_all(queryable, updates, opts \\ []),
    do: Florina.Repo.update_all(queryable, updates, put(opts))

  def delete_all(queryable, opts \\ []), do: Florina.Repo.delete_all(queryable, put(opts))

  # --- preload / transaction -------------------------------------------------
  def preload(structs_or_struct_or_nil, preloads, opts \\ []),
    do: Florina.Repo.preload(structs_or_struct_or_nil, preloads, put(opts))

  @doc """
  Run `fun` in a transaction on `Florina.Repo`. Queries inside `fun` still read
  `Process.get(:tenant_prefix)` per call, so they land in the tenant schema;
  the prefix is also injected into the transaction opts for completeness.
  """
  def transaction(fun, opts \\ []), do: Florina.Repo.transaction(fun, put(opts))
end
