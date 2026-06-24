# Multi-Tenant Database Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Phoenix database-per-tenant routing — resolve a tenant from the subdomain, pin all data access to that tenant's own database, fail closed for unknown tenants — and prove isolation with a local leakage test.

**Architecture:** The existing `Florina.Repo` becomes the control-plane database and gains a `tenants` registry table. A new dynamic repo `Florina.TenantRepo` (deliberately NOT in `:ecto_repos`) is started once per tenant by a `ConnectionManager` GenServer and pinned per request via `put_dynamic_repo/1`. A `ResolveTenant` plug reads the subdomain, looks the tenant up, pins its connection, and halts with 404 if resolution fails. A throwaway `tenant_markers` table + `/whoami` page make isolation visible in a browser.

**Tech Stack:** Elixir, Phoenix 1.8, Ecto 3.13 + Postgres, Ecto dynamic repositories, Ecto.Migrator.

---

## Notes for the executor (read first)

- **Tests are local-only and git-ignored.** Write them under `test/` and run them, but do
  **not** `git add` test files — commits stage only `lib/`, `priv/`, `config/`, `docs/`.
- **Local Postgres** uses trust auth: username `alex`, empty password, host `localhost`
  (see `config/dev.exs`). The connection manager reuses these base settings.
- **Branching:** work on `develop`. Never push or merge to `main`.
- **`mix test` auto-creates/migrates** the `florina_test` database (see the `test` alias),
  so running any test file also sets up the control-plane test DB.
- The cross-database tests create real extra databases on your machine
  (`florina_tenant_acme_test`, `florina_tenant_globex_test`). That's expected and idempotent.

---

## File structure

**Create (source — committed):**
- `lib/florina/tenants/tenant.ex` — registry schema
- `lib/florina/tenants.ex` — registry context (list / get_by_slug / register)
- `lib/florina/tenants/subdomain.ex` — pure subdomain→slug extraction
- `lib/florina/tenant_repo.ex` — the dynamic per-tenant repo
- `lib/florina/tenants/marker.ex` — throwaway proof schema (`tenant_markers`)
- `lib/florina/tenants/connection_manager.ex` — per-tenant pool manager (GenServer)
- `lib/florina/tenants/provisioner.ex` — create DB → register → migrate
- `lib/florina/tenants/migrator.ex` — run tenant migrations across tenants
- `lib/florina_web/plugs/resolve_tenant.ex` — resolve + pin + fail closed
- `lib/florina_web/controllers/whoami_controller.ex` — diagnostic page
- `lib/mix/tasks/florina.tenants.setup.ex` — provision local demo tenants
- `priv/repo/migrations/<ts>_create_tenants.exs` — control-plane registry table
- `priv/tenant_repo/migrations/<ts>_create_tenant_markers.exs` — tenant proof table

**Create (tests — local only, NOT committed):**
- `test/support/tenant_case.ex`
- `test/florina/tenants_test.exs`
- `test/florina/tenants/subdomain_test.exs`
- `test/florina/tenants/connection_manager_test.exs`
- `test/florina/tenants/migrator_test.exs`
- `test/florina/tenants/isolation_test.exs`
- `test/florina_web/plugs/resolve_tenant_test.exs`

**Modify (committed):**
- `lib/florina/application.ex` — start `ConnectionManager`
- `lib/florina_web/router.ex` — `:resolve_tenant` pipeline + `/whoami` route
- `config/config.exs` — `tenant_pool_size`
- `config/dev.exs` — `tenant_base_host`
- `config/test.exs` — `tenant_base_host`
- `config/runtime.exs` — `tenant_base_host` (prod)
- `DEPLOY.md` — note the foundation + how to run the demo

---

## Task 1: Control-plane `tenants` registry (table + schema + context)

**Files:**
- Create: `lib/florina/tenants/tenant.ex`
- Create: `lib/florina/tenants.ex`
- Create: `priv/repo/migrations/<ts>_create_tenants.exs`
- Test: `test/florina/tenants_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/florina/tenants_test.exs`:

```elixir
defmodule Florina.TenantsTest do
  use Florina.DataCase, async: true
  alias Florina.Tenants

  test "register/1 then get_by_slug/1 returns the tenant" do
    {:ok, t} = Tenants.register(%{slug: "reg_alpha", name: "Alpha", database: "db_alpha"})
    assert t.slug == "reg_alpha"
    assert Tenants.get_by_slug("reg_alpha").database == "db_alpha"
  end

  test "get_by_slug/1 returns nil for an unknown slug" do
    assert Tenants.get_by_slug("reg_missing") == nil
  end

  test "register/1 is idempotent on slug" do
    {:ok, _} = Tenants.register(%{slug: "reg_dup", name: "First", database: "db1"})
    {:ok, _} = Tenants.register(%{slug: "reg_dup", name: "Second", database: "db2"})
    assert Enum.count(Tenants.list(), &(&1.slug == "reg_dup")) == 1
    assert Tenants.get_by_slug("reg_dup").name == "First"
  end

  test "list/0 includes registered tenants" do
    {:ok, _} = Tenants.register(%{slug: "reg_one", name: "One", database: "d1"})
    {:ok, _} = Tenants.register(%{slug: "reg_two", name: "Two", database: "d2"})
    slugs = Enum.map(Tenants.list(), & &1.slug)
    assert "reg_one" in slugs
    assert "reg_two" in slugs
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/florina/tenants_test.exs`
Expected: FAIL — compile error, `Florina.Tenants.__struct__/0 is undefined` / module `Florina.Tenants` is not available.

- [ ] **Step 3: Generate the migration**

Run: `mix ecto.gen.migration create_tenants`
Then replace the generated file's body so it reads:

```elixir
defmodule Florina.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :database, :string, null: false
      add :active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:tenants, [:slug])
  end
end
```

- [ ] **Step 4: Write the schema**

Create `lib/florina/tenants/tenant.ex`:

```elixir
defmodule Florina.Tenants.Tenant do
  @moduledoc "A tenant in the control-plane registry: which database is theirs."
  use Ecto.Schema
  import Ecto.Changeset

  schema "tenants" do
    field :slug, :string
    field :name, :string
    field :database, :string
    field :active, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name, :database, :active])
    |> validate_required([:slug, :name, :database])
    |> unique_constraint(:slug)
  end
end
```

- [ ] **Step 5: Write the context**

Create `lib/florina/tenants.ex`:

```elixir
defmodule Florina.Tenants do
  @moduledoc "Control-plane registry of tenants and which database each one lives in."
  import Ecto.Query, only: [from: 2]
  alias Florina.Repo
  alias Florina.Tenants.Tenant

  def list, do: Repo.all(from t in Tenant, order_by: t.slug)

  def get_by_slug(slug) when is_binary(slug), do: Repo.get_by(Tenant, slug: slug)
  def get_by_slug(_), do: nil

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
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/florina/tenants_test.exs`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 7: Apply the migration to the dev database**

Run: `mix ecto.migrate`
Expected: migration `create_tenants` runs against `florina_dev` without error.

- [ ] **Step 8: Commit (source only — tests are git-ignored)**

```bash
git add lib/florina/tenants.ex lib/florina/tenants/tenant.ex priv/repo/migrations
git commit -m "feat: control-plane tenant registry (table, schema, context)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Subdomain extraction (pure function)

**Files:**
- Create: `lib/florina/tenants/subdomain.ex`
- Test: `test/florina/tenants/subdomain_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/florina/tenants/subdomain_test.exs`:

```elixir
defmodule Florina.Tenants.SubdomainTest do
  use ExUnit.Case, async: true
  alias Florina.Tenants.Subdomain

  test "extracts the tenant label from the subdomain" do
    assert Subdomain.extract("acme.localhost", "localhost") == "acme"
    assert Subdomain.extract("globex.localhost", "localhost") == "globex"
    assert Subdomain.extract("acme.florina.app", "florina.app") == "acme"
  end

  test "returns nil when there is no subdomain" do
    assert Subdomain.extract("localhost", "localhost") == nil
  end

  test "returns nil for a mismatched base host" do
    assert Subdomain.extract("acme.example.com", "localhost") == nil
  end

  test "returns nil for multi-level subdomains (fail closed)" do
    assert Subdomain.extract("a.b.localhost", "localhost") == nil
  end

  test "returns nil for non-binary input" do
    assert Subdomain.extract(nil, "localhost") == nil
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/florina/tenants/subdomain_test.exs`
Expected: FAIL — module `Florina.Tenants.Subdomain` is not available.

- [ ] **Step 3: Write the implementation**

Create `lib/florina/tenants/subdomain.ex`:

```elixir
defmodule Florina.Tenants.Subdomain do
  @moduledoc """
  Extracts the tenant slug from a request host, given the base host.
  Only a single subdomain label directly left of the base host is accepted;
  anything else returns nil so resolution fails closed.
  """
  def extract(host, base) when is_binary(host) and is_binary(base) do
    case String.split(host, ".", parts: 2) do
      [sub, ^base] when sub != "" -> sub
      _ -> nil
    end
  end

  def extract(_host, _base), do: nil
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/florina/tenants/subdomain_test.exs`
Expected: PASS — 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/florina/tenants/subdomain.ex
git commit -m "feat: subdomain-to-tenant-slug extraction

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Dynamic `TenantRepo` + tenant marker table + marker schema

**Files:**
- Create: `lib/florina/tenant_repo.ex`
- Create: `priv/tenant_repo/migrations/<ts>_create_tenant_markers.exs`
- Create: `lib/florina/tenants/marker.ex`

This task has no unit test (the repo is exercised end-to-end in Task 5/6); verification is a clean compile and confirming the repo is NOT registered for automatic migration.

- [ ] **Step 1: Write the dynamic repo**

Create `lib/florina/tenant_repo.ex`:

```elixir
defmodule Florina.TenantRepo do
  @moduledoc """
  Dynamic, per-tenant repository. It has NO fixed database. The connection
  manager starts a named instance per tenant; each request pins the right one
  with `put_dynamic_repo/1`. Deliberately absent from `:ecto_repos`, so the
  normal `mix ecto.migrate` and the release migrator never touch it.
  """
  use Ecto.Repo, otp_app: :florina, adapter: Ecto.Adapters.Postgres
end
```

- [ ] **Step 2: Write the marker schema**

Create `lib/florina/tenants/marker.ex`:

```elixir
defmodule Florina.Tenants.Marker do
  @moduledoc """
  Throwaway proof-of-isolation table; one of these lives in EACH tenant
  database. Used by the leakage test and the /whoami diagnostic page.
  Remove once real per-tenant consumers are wired.
  """
  use Ecto.Schema

  schema "tenant_markers" do
    field :label, :string
    timestamps(type: :utc_datetime)
  end
end
```

- [ ] **Step 3: Generate the tenant migration into its own path**

Run: `mix ecto.gen.migration create_tenant_markers --migrations-path priv/tenant_repo/migrations`
Then replace the generated file's body so it reads:

```elixir
defmodule Florina.TenantRepo.Migrations.CreateTenantMarkers do
  use Ecto.Migration

  def change do
    create table(:tenant_markers) do
      add :label, :string, null: false
      timestamps(type: :utc_datetime)
    end
  end
end
```

- [ ] **Step 4: Verify it compiles and the repo is not auto-migrated**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly.

Run: `grep -n "ecto_repos" config/config.exs`
Expected: shows `ecto_repos: [Florina.Repo]` only — `Florina.TenantRepo` must NOT appear.

- [ ] **Step 5: Commit**

```bash
git add lib/florina/tenant_repo.ex lib/florina/tenants/marker.ex priv/tenant_repo/migrations
git commit -m "feat: dynamic TenantRepo + per-tenant marker table

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: ConnectionManager + supervision + config

**Files:**
- Create: `lib/florina/tenants/connection_manager.ex`
- Modify: `lib/florina/application.ex`
- Modify: `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs`
- Test: `test/florina/tenants/connection_manager_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/florina/tenants/connection_manager_test.exs`:

```elixir
defmodule Florina.Tenants.ConnectionManagerTest do
  # async: false → DataCase runs the sandbox in shared mode, so the
  # ConnectionManager GenServer can read Florina.Repo.
  use Florina.DataCase, async: false
  alias Florina.Tenants.ConnectionManager

  test "ensure_started/1 returns an error for an unknown tenant" do
    assert ConnectionManager.ensure_started("definitely-not-a-tenant") ==
             {:error, :unknown_tenant}
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/florina/tenants/connection_manager_test.exs`
Expected: FAIL — module `Florina.Tenants.ConnectionManager` is not available.

- [ ] **Step 3: Write the ConnectionManager**

Create `lib/florina/tenants/connection_manager.ex`:

```elixir
defmodule Florina.Tenants.ConnectionManager do
  @moduledoc """
  Starts, caches and reuses exactly one connection pool per tenant database.
  Returns the pid of a started `Florina.TenantRepo` instance; callers pin it
  with `Florina.TenantRepo.put_dynamic_repo/1`.
  """
  use GenServer
  alias Florina.Tenants

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Returns {:ok, pid} for a known tenant, or {:error, reason}."
  def ensure_started(slug), do: GenServer.call(__MODULE__, {:ensure, slug})

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:ensure, slug}, _from, state) do
    case state do
      %{^slug => pid} ->
        if Process.alive?(pid),
          do: {:reply, {:ok, pid}, state},
          else: start(slug, Map.delete(state, slug))

      _ ->
        start(slug, state)
    end
  end

  defp start(slug, state) do
    case Tenants.get_by_slug(slug) do
      nil ->
        {:reply, {:error, :unknown_tenant}, state}

      tenant ->
        case Florina.TenantRepo.start_link(connection_opts(tenant)) do
          {:ok, pid} -> {:reply, {:ok, pid}, Map.put(state, slug, pid)}
          {:error, {:already_started, pid}} -> {:reply, {:ok, pid}, Map.put(state, slug, pid)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # Reuse the control-plane DB's host/credentials; override only the database
  # name (from the registry). name: nil starts an unnamed, dynamic instance.
  defp connection_opts(tenant) do
    Application.get_env(:florina, Florina.Repo)
    |> Keyword.take([:username, :password, :hostname, :port])
    |> Keyword.merge(
      name: nil,
      database: tenant.database,
      pool_size: Application.get_env(:florina, :tenant_pool_size, 2)
    )
  end
end
```

- [ ] **Step 4: Start the manager in the supervision tree**

In `lib/florina/application.ex`, add `Florina.Tenants.ConnectionManager` to `children`
immediately after `Florina.Repo`:

```elixir
    children = [
      FlorinaWeb.Telemetry,
      Florina.Repo,
      Florina.Tenants.ConnectionManager,
      {DNSCluster, query: Application.get_env(:florina, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Florina.PubSub},
      # Background job processing (Oban)
      {Oban, Application.fetch_env!(:florina, Oban)},
      # Start a worker by calling: Florina.Worker.start_link(arg)
      # {Florina.Worker, arg},
      # Start to serve requests, typically the last entry
      FlorinaWeb.Endpoint
    ]
```

- [ ] **Step 5: Add config**

In `config/config.exs`, after the `:dashboard_auth` line, add:

```elixir
# Tenancy: connection pool size for each per-tenant database.
config :florina, :tenant_pool_size, 2
```

In `config/dev.exs`, at the end of the file, add:

```elixir
# Tenancy: requests like acme.localhost resolve the tenant "acme".
config :florina, :tenant_base_host, "localhost"
```

In `config/test.exs`, at the end of the file, add:

```elixir
config :florina, :tenant_base_host, "localhost"
```

In `config/runtime.exs`, inside the `if config_env() == :prod do` block (e.g. right after
the `host = ...` line), add:

```elixir
  config :florina, :tenant_base_host, System.get_env("TENANT_BASE_HOST") || host
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/florina/tenants/connection_manager_test.exs`
Expected: PASS — 1 test, 0 failures.

- [ ] **Step 7: Verify the app still boots cleanly**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly.

- [ ] **Step 8: Commit**

```bash
git add lib/florina/tenants/connection_manager.ex lib/florina/application.ex config/config.exs config/dev.exs config/test.exs config/runtime.exs
git commit -m "feat: per-tenant connection manager + tenancy config

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Provisioner + Migrator + test support

**Files:**
- Create: `lib/florina/tenants/migrator.ex`
- Create: `lib/florina/tenants/provisioner.ex`
- Create: `test/support/tenant_case.ex` (test-only)
- Test: `test/florina/tenants/migrator_test.exs`

- [ ] **Step 1: Write the Migrator**

Create `lib/florina/tenants/migrator.ex`:

```elixir
defmodule Florina.Tenants.Migrator do
  @moduledoc "Runs the per-tenant migrations against tenant databases."

  @doc "Migrate every registered tenant's database."
  def migrate_all do
    for tenant <- Florina.Tenants.list() do
      {:ok, pid} = Florina.Tenants.ConnectionManager.ensure_started(tenant.slug)
      migrate_one(pid)
    end

    :ok
  end

  @doc "Migrate a single tenant database, given a started TenantRepo pid."
  def migrate_one(pid) do
    Ecto.Migrator.run(Florina.TenantRepo, path(), :up, all: true, dynamic_repo: pid)
  end

  defp path, do: Path.join([:code.priv_dir(:florina), "tenant_repo", "migrations"])
end
```

- [ ] **Step 2: Write the Provisioner**

Create `lib/florina/tenants/provisioner.ex`:

```elixir
defmodule Florina.Tenants.Provisioner do
  @moduledoc """
  Operator-driven onboarding for a tenant: create the database, register it in
  the control plane, and migrate it. Idempotent — safe to run repeatedly.
  """
  alias Florina.Tenants
  alias Florina.Tenants.{ConnectionManager, Migrator}

  def provision(%{slug: slug, name: name, database: database}) do
    :ok = create_database(database)
    {:ok, _} = Tenants.register(%{slug: slug, name: name, database: database})
    {:ok, pid} = ConnectionManager.ensure_started(slug)
    Migrator.migrate_one(pid)
    {:ok, Tenants.get_by_slug(slug)}
  end

  defp create_database(database) do
    opts =
      Application.get_env(:florina, Florina.Repo)
      |> Keyword.take([:username, :password, :hostname, :port])
      |> Keyword.put(:database, database)

    case Ecto.Adapters.Postgres.storage_up(opts) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "could not create tenant database #{database}: #{inspect(reason)}"
    end
  end
end
```

- [ ] **Step 3: Write the test support case**

Create `test/support/tenant_case.ex`:

```elixir
defmodule Florina.TenantCase do
  @moduledoc """
  Test case for cross-tenant database tests. Provisions two real test
  databases (acme, globex), shares the control-plane sandbox connection so the
  ConnectionManager can read the registry, and truncates the marker table
  before each test. Not for the SQL sandbox on tenant data — tenant repos use
  real connections.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import Florina.TenantCase
      alias Florina.{Tenants, TenantRepo}
      alias Florina.Tenants.{ConnectionManager, Marker}
    end
  end

  @tenants [
    {"acme", "Acme", "florina_tenant_acme_test"},
    {"globex", "Globex", "florina_tenant_globex_test"}
  ]

  def test_tenants, do: @tenants

  setup _tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Florina.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    ensure_test_tenants!()
    reset_markers!()
    :ok
  end

  def ensure_test_tenants! do
    for {slug, name, db} <- @tenants do
      {:ok, _} = Florina.Tenants.Provisioner.provision(%{slug: slug, name: name, database: db})
    end
  end

  def reset_markers! do
    for {slug, _name, _db} <- @tenants do
      {:ok, pid} = Florina.Tenants.ConnectionManager.ensure_started(slug)
      Florina.TenantRepo.put_dynamic_repo(pid)
      Florina.TenantRepo.delete_all(Florina.Tenants.Marker)
    end
  end
end
```

- [ ] **Step 4: Write the failing Migrator test**

Create `test/florina/tenants/migrator_test.exs`:

```elixir
defmodule Florina.Tenants.MigratorTest do
  use Florina.TenantCase
  alias Florina.Tenants.Migrator

  test "migrate_all/0 leaves every tenant's markers table queryable" do
    assert Migrator.migrate_all() == :ok

    for {slug, _name, _db} <- test_tenants() do
      {:ok, pid} = ConnectionManager.ensure_started(slug)
      TenantRepo.put_dynamic_repo(pid)
      assert is_list(TenantRepo.all(from m in Marker, select: m.id))
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/florina/tenants/migrator_test.exs`
Expected: PASS — 1 test, 0 failures. (On first run it creates the two
`florina_tenant_*_test` databases; that is expected.)

- [ ] **Step 6: Commit**

```bash
git add lib/florina/tenants/migrator.ex lib/florina/tenants/provisioner.ex
git commit -m "feat: tenant provisioning + per-tenant migration runner

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: The leakage test (isolation proof — the centerpiece)

**Files:**
- Test: `test/florina/tenants/isolation_test.exs`

This is the headline guarantee. No new source code — it validates Tasks 1–5 together.

- [ ] **Step 1: Write the isolation test**

Create `test/florina/tenants/isolation_test.exs`:

```elixir
defmodule Florina.Tenants.IsolationTest do
  use Florina.TenantCase

  test "a request resolved as one tenant cannot reach another tenant's data" do
    {:ok, acme} = ConnectionManager.ensure_started("acme")
    {:ok, globex} = ConnectionManager.ensure_started("globex")

    TenantRepo.put_dynamic_repo(acme)
    TenantRepo.insert!(%Marker{label: "acme-secret"})

    TenantRepo.put_dynamic_repo(globex)
    TenantRepo.insert!(%Marker{label: "globex-secret"})

    # Resolved as acme: see only acme's data.
    TenantRepo.put_dynamic_repo(acme)
    acme_labels = TenantRepo.all(from m in Marker, select: m.label)
    assert acme_labels == ["acme-secret"]
    refute "globex-secret" in acme_labels

    # Resolved as globex: see only globex's data.
    TenantRepo.put_dynamic_repo(globex)
    globex_labels = TenantRepo.all(from m in Marker, select: m.label)
    assert globex_labels == ["globex-secret"]
    refute "acme-secret" in globex_labels
  end
end
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `mix test test/florina/tenants/isolation_test.exs`
Expected: PASS — 1 test, 0 failures.

- [ ] **Step 3: Run the whole tenancy suite together (catch cross-test interference)**

Run: `mix test test/florina/tenants test/florina/tenants_test.exs`
Expected: PASS — all tenancy tests, 0 failures.

- [ ] **Step 4: Commit**

There is no source change here (the test is git-ignored), so there is nothing to commit.
Confirm with: `git status --short` (expected: clean, or only untracked test files).

---

## Task 7: ResolveTenant plug (resolve + pin + fail closed)

**Files:**
- Create: `lib/florina_web/plugs/resolve_tenant.ex`
- Test: `test/florina_web/plugs/resolve_tenant_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/florina_web/plugs/resolve_tenant_test.exs`:

```elixir
defmodule FlorinaWeb.Plugs.ResolveTenantTest do
  use Florina.TenantCase
  import Plug.Test
  alias FlorinaWeb.Plugs.ResolveTenant

  test "a known subdomain resolves and assigns the tenant" do
    conn =
      conn(:get, "/whoami")
      |> Map.put(:host, "acme.localhost")
      |> ResolveTenant.call([])

    refute conn.halted
    assert conn.assigns.tenant.slug == "acme"
  end

  test "an unknown subdomain fails closed with 404" do
    conn =
      conn(:get, "/whoami")
      |> Map.put(:host, "nope.localhost")
      |> ResolveTenant.call([])

    assert conn.halted
    assert conn.status == 404
  end

  test "no subdomain fails closed with 404" do
    conn =
      conn(:get, "/whoami")
      |> Map.put(:host, "localhost")
      |> ResolveTenant.call([])

    assert conn.halted
    assert conn.status == 404
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/florina_web/plugs/resolve_tenant_test.exs`
Expected: FAIL — module `FlorinaWeb.Plugs.ResolveTenant` is not available.

- [ ] **Step 3: Write the plug**

Create `lib/florina_web/plugs/resolve_tenant.ex`:

```elixir
defmodule FlorinaWeb.Plugs.ResolveTenant do
  @moduledoc """
  Resolves the tenant from the request subdomain, pins `Florina.TenantRepo` to
  that tenant's database, and assigns the tenant on the conn. Fails closed
  (404, halted) when the tenant cannot be resolved.
  """
  import Plug.Conn
  alias Florina.Tenants
  alias Florina.Tenants.{ConnectionManager, Subdomain}

  def init(opts), do: opts

  def call(conn, _opts) do
    base = Application.get_env(:florina, :tenant_base_host, "localhost")

    with slug when is_binary(slug) <- Subdomain.extract(conn.host, base),
         %Tenants.Tenant{} = tenant <- Tenants.get_by_slug(slug),
         {:ok, pid} <- ConnectionManager.ensure_started(tenant.slug) do
      Florina.TenantRepo.put_dynamic_repo(pid)
      assign(conn, :tenant, tenant)
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Unknown tenant")
        |> halt()
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/florina_web/plugs/resolve_tenant_test.exs`
Expected: PASS — 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/florina_web/plugs/resolve_tenant.ex
git commit -m "feat: ResolveTenant plug (subdomain -> pinned DB, fail closed)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: `/whoami` diagnostic page + demo setup task + see it work

**Files:**
- Create: `lib/florina_web/controllers/whoami_controller.ex`
- Modify: `lib/florina_web/router.ex`
- Create: `lib/mix/tasks/florina.tenants.setup.ex`

- [ ] **Step 1: Write the diagnostic controller**

Create `lib/florina_web/controllers/whoami_controller.ex`:

```elixir
defmodule FlorinaWeb.WhoamiController do
  @moduledoc "Throwaway diagnostic: shows the resolved tenant and a value from THEIR database."
  use FlorinaWeb, :controller
  import Ecto.Query, only: [from: 2]
  alias Florina.Tenants.Marker

  def show(conn, _params) do
    tenant = conn.assigns.tenant
    labels = Florina.TenantRepo.all(from m in Marker, select: m.label)
    text(conn, "tenant: #{tenant.slug} (#{tenant.name})\nmarkers: #{Enum.join(labels, ", ")}")
  end
end
```

- [ ] **Step 2: Add the pipeline and route**

In `lib/florina_web/router.ex`, add a pipeline after the `:dashboard_auth` pipeline block:

```elixir
  pipeline :resolve_tenant do
    plug FlorinaWeb.Plugs.ResolveTenant
  end
```

And add a new scope (place it after the existing `live "/calls"` / `live "/chat"` scope):

```elixir
  scope "/", FlorinaWeb do
    pipe_through [:browser, :resolve_tenant]
    get "/whoami", WhoamiController, :show
  end
```

- [ ] **Step 3: Write the demo setup mix task**

Create `lib/mix/tasks/florina.tenants.setup.ex`:

```elixir
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
```

- [ ] **Step 4: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly.

- [ ] **Step 5: Provision the demo tenants**

Run: `mix florina.tenants.setup`
Expected output includes:
```
provisioned acme -> florina_tenant_acme_dev
provisioned globex -> florina_tenant_globex_dev
```

- [ ] **Step 6: See isolation work over HTTP**

Start the server in the background: `mix phx.server`
(Wait until it reports running on port 4000.)

Run each check (the `Host` header simulates the subdomain):

```bash
curl -s -H "Host: acme.localhost" http://127.0.0.1:4000/whoami
```
Expected: `tenant: acme (Acme Corp)` and `markers: acme-secret`.

```bash
curl -s -H "Host: globex.localhost" http://127.0.0.1:4000/whoami
```
Expected: `tenant: globex (Globex Inc)` and `markers: globex-secret`.

```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: localhost" http://127.0.0.1:4000/whoami
```
Expected: `404`.

Stop the server when done.

- [ ] **Step 7: Commit**

```bash
git add lib/florina_web/controllers/whoami_controller.ex lib/florina_web/router.ex lib/mix/tasks/florina.tenants.setup.ex
git commit -m "feat: /whoami diagnostic page + demo tenant setup task

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Docs + full verification + wrap-up

**Files:**
- Modify: `DEPLOY.md`

- [ ] **Step 1: Document the foundation**

In `DEPLOY.md`, add a short section (adapt to the file's existing structure):

```markdown
## Multi-tenant database foundation (local)

Phoenix can route each customer to their own physically separate database.

- Tenant is resolved from the **subdomain** (`acme.localhost`, `globex.localhost`).
- The control-plane database (the main app DB) holds a `tenants` registry.
- Set up two local demo tenants: `mix florina.tenants.setup`
- See it work: visit `http://acme.localhost:4000/whoami` vs `http://globex.localhost:4000/whoami`.

Not yet wired to `/calls` or `/chat`, and not yet connected to production databases —
those are later slices.
```

- [ ] **Step 2: Run the full local test suite**

Run: `mix test`
Expected: PASS — full suite, 0 failures.

- [ ] **Step 3: Run the project precommit gate**

Run: `mix precommit`
Expected: compile (warnings as errors) + format + unused-deps + tests all pass.
If `mix format` changes files, include them in the final commit.

- [ ] **Step 4: Confirm the git remote is the sandbox fork (safety)**

Run: `git remote -v`
Expected: every line points at `alexandruradulescu-neurony/florina-elixir`. If
`neurony/florina` appears anywhere, STOP — wrong repo.

- [ ] **Step 5: Final commit**

```bash
git add DEPLOY.md
git commit -m "docs: note the multi-tenant database foundation in DEPLOY.md

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: Report**

Summarize for the maintainer in plain English: what was built, that the leakage test
passes, that `/calls` and `/chat` are untouched, and that nothing was deployed (work is on
`develop`). Confirm the deploy decision is theirs.

---

## Deviation from the spec (intentional)

The spec listed a LiveView `on_mount` tenant hook (`FlorinaWeb.TenantHook`). It is
**deferred to the consumer-wiring slice**: it is only meaningful with a live consumer (none
exists in this foundation), and building it now would mean either untested code or a
contrived test harness. The resolution logic it will use (`Subdomain` + `Tenants` +
`ConnectionManager`) is fully built and tested here, so adding the hook later — tested
against a real LiveView — is small. The spec's "known gotcha" about re-pinning the tenant
inside LiveView-spawned tasks still applies when that slice happens.
