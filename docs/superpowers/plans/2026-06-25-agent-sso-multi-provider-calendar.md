# Agent SSO + Multi-Provider Calendar (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let sales agents sign in to a tenant with their own Google or Microsoft work account (auto-approved by company-email domain), connect their calendar in the same step, and view a merged calendar of all agents' appointments.

**Architecture:** A provider-agnostic OAuth layer (two behaviours + a dispatcher) with Google and Microsoft implementations. One unified per-tenant `oauth_credentials` table (replacing the Google-only one) and a per-tenant `calendar_events` store that backs the merged view. Agent sessions (`AgentAuth`) gate the agent-facing pages, replacing the shared dashboard password. The existing 30-min sync becomes provider-aware and writes every agent's events into `calendar_events`.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto (per-tenant dynamic repo), Cloak (encrypted columns), Req (HTTP), Phoenix.Token (signed OAuth state), LiveView. Spec: [agent-sso-multi-provider-calendar-email-design](../specs/2026-06-25-agent-sso-multi-provider-calendar-email-design.md).

---

## Conventions for this plan

- **Tests are local-only and git-ignored.** Write them under `test/`, run them, but they are never committed. Commits contain only `lib/`, `priv/`, `config/`, `docs/`.
- **Per-tenant DB tests** use `Florina.TenantCase` (pins a throwaway tenant repo). **Control-plane / web tests** use `FlorinaWeb.ConnCase` or `Florina.DataCase`. Match whichever an existing sibling test uses.
- After each task: run `mix precommit` (compile warnings-as-errors + format + unused-deps + tests) before committing. Each commit MUST leave the tree compiling and `mix precommit` green.
- Branch: work on `develop`. Never touch `main`.
- Provider values are atoms `:google | :microsoft` in Elixir, stored as strings in Postgres (`Ecto.Enum`).

---

# SLICE 1 — Sign in with Google (foundation)

Produces working software: an agent visits `/t/<slug>/login`, clicks **Sign in with Google**, is gated by company email, gets an account + calendar connection, and lands logged-in. Microsoft (Slice 2) and the merged view (Slice 3) build on this.

---

### Task 1: Control-plane — `allowed_email_domains` on tenants

**Files:**
- Create: `priv/repo/migrations/20260625130000_add_allowed_email_domains_to_tenants.exs`
- Modify: `lib/florina/tenants/tenant.ex`
- Modify: `lib/florina/tenants.ex` (add `set_allowed_domains/2`)
- Test: `test/florina/tenants_allowed_domains_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina/tenants_allowed_domains_test.exs
defmodule Florina.TenantsAllowedDomainsTest do
  use Florina.DataCase, async: true
  alias Florina.Tenants

  test "register + set_allowed_domains stores a downcased domain list" do
    {:ok, t} =
      Tenants.register(%{
        slug: "dommatch",
        name: "Dom Match",
        database: "florina_tenant_dommatch",
        allowed_email_domains: ["Leadder.com", "acme.io"]
      })

    assert t.allowed_email_domains == ["leadder.com", "acme.io"]

    {:ok, t2} = Tenants.set_allowed_domains("dommatch", ["only.com"])
    assert t2.allowed_email_domains == ["only.com"]
  end
end
```

- [ ] **Step 2: Run it — expect FAIL** (`** (KeyError) key :allowed_email_domains` or unknown field)

Run: `mix test test/florina/tenants_allowed_domains_test.exs`

- [ ] **Step 3: Migration**

```elixir
# priv/repo/migrations/20260625130000_add_allowed_email_domains_to_tenants.exs
defmodule Florina.Repo.Migrations.AddAllowedEmailDomainsToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :allowed_email_domains, {:array, :string}, null: false, default: []
    end
  end
end
```

- [ ] **Step 4: Schema + changeset (downcase on cast)**

In `lib/florina/tenants/tenant.ex`, add the field inside `schema "tenants"`:

```elixir
    field :allowed_email_domains, {:array, :string}, default: []
```

and update `changeset/2`:

```elixir
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name, :database, :active, :status, :allowed_email_domains])
    |> validate_required([:slug, :name, :database])
    |> validate_inclusion(:status, @valid_statuses)
    |> normalize_domains()
    |> unique_constraint(:slug)
  end

  defp normalize_domains(changeset) do
    case Ecto.Changeset.get_change(changeset, :allowed_email_domains) do
      nil ->
        changeset

      domains ->
        cleaned =
          domains
          |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
          |> Enum.reject(&(&1 == ""))

        Ecto.Changeset.put_change(changeset, :allowed_email_domains, cleaned)
    end
  end
```

- [ ] **Step 5: Context setter**

In `lib/florina/tenants.ex`, add:

```elixir
  @doc "Replace a tenant's allowed email-domain list."
  def set_allowed_domains(slug, domains) when is_list(domains) do
    case get_by_slug(slug) do
      nil -> {:error, :not_found}
      tenant -> tenant |> Tenant.changeset(%{allowed_email_domains: domains}) |> Repo.update()
    end
  end
```

(Confirm `alias Florina.Tenants.Tenant` and `alias Florina.Repo` already exist at the top of `tenants.ex`; add whichever is missing.)

- [ ] **Step 6: Migrate + run test — expect PASS**

Run: `mix ecto.migrate && mix test test/florina/tenants_allowed_domains_test.exs`

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/florina/tenants/tenant.ex lib/florina/tenants.ex
git commit -m "feat(tenants): allowed_email_domains for company-email sign-in gate"
```

---

### Task 2: Per-tenant — `active` on agents + email lookup/upsert

**Files:**
- Create: `priv/tenant_repo/migrations/20260625130500_add_active_to_voice_user.exs`
- Modify: `lib/florina/accounts/user.ex`
- Modify: `lib/florina/accounts.ex`
- Test: `test/florina/accounts_identity_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina/accounts_identity_test.exs
defmodule Florina.AccountsIdentityTest do
  use Florina.TenantCase, async: true
  alias Florina.Accounts

  test "upsert_agent_from_identity creates an active sales agent, then finds it again" do
    id = %{email: "Jane@Leadder.com", name: "Jane Doe", email_verified: true, subject: "s1"}

    {:ok, agent} = Accounts.upsert_agent_from_identity(id)
    assert agent.is_sales_agent
    assert agent.active
    assert agent.email == "jane@leadder.com"

    {:ok, again} = Accounts.upsert_agent_from_identity(id)
    assert again.id == agent.id
  end

  test "upsert refuses a deactivated agent" do
    {:ok, agent} = Accounts.create_user(%{username: "x@leadder.com", email: "x@leadder.com", is_sales_agent: true})
    {:ok, _} = Accounts.update_user(agent, %{active: false})

    assert {:error, :inactive} =
             Accounts.upsert_agent_from_identity(%{email: "x@leadder.com", name: "X", email_verified: true, subject: "s"})
  end
end
```

- [ ] **Step 2: Run it — expect FAIL** (unknown field `active` / function undefined)

Run: `mix test test/florina/accounts_identity_test.exs`

- [ ] **Step 3: Migration**

```elixir
# priv/tenant_repo/migrations/20260625130500_add_active_to_voice_user.exs
defmodule Florina.Repo.Migrations.AddActiveToVoiceUser do
  use Ecto.Migration

  def change do
    alter table(:voice_user) do
      add :active, :boolean, null: false, default: true
    end
  end
end
```

- [ ] **Step 4: Schema field**

In `lib/florina/accounts/user.ex`, add to the schema:

```elixir
    field :active, :boolean, default: true
```

and add `:active` to `@optional_fields`.

- [ ] **Step 5: Context — email lookup + identity upsert**

In `lib/florina/accounts.ex`, add (and add `import Ecto.Query` already present):

```elixir
  @doc "Find a user by email (case-insensitive). Returns nil if not found."
  def get_user_by_email(email) when is_binary(email) do
    down = String.downcase(email)
    User |> where([u], fragment("lower(?)", u.email) == ^down) |> TenantRepo.one()
  end

  @doc """
  Create-or-find a sales agent from a verified OAuth identity.

  Returns `{:ok, user}`, or `{:error, :inactive}` if a matching agent is deactivated.
  """
  def upsert_agent_from_identity(%{email: email} = identity) when is_binary(email) do
    down = String.downcase(email)

    case get_user_by_email(down) do
      nil ->
        create_user(%{
          username: down,
          email: down,
          first_name: identity[:name],
          is_sales_agent: true,
          active: true
        })

      %User{active: false} ->
        {:error, :inactive}

      %User{} = user ->
        update_user(user, %{is_sales_agent: true})
    end
  end
```

Note: `where([u], fragment("lower(?)", u.email) == ^down)` needs `import Ecto.Query` — it is already imported in `accounts.ex` (`order_by/2, where/2`); change that import to the bare `import Ecto.Query` so `fragment/1` and the binding form are available.

- [ ] **Step 6: Migrate tenants + run test — expect PASS**

Run: `mix test test/florina/accounts_identity_test.exs`
(The `TenantCase` setup runs tenant migrations against the throwaway tenant DB, so the new column is present.)

- [ ] **Step 7: Commit**

```bash
git add priv/tenant_repo/migrations lib/florina/accounts/user.ex lib/florina/accounts.ex
git commit -m "feat(accounts): agent active flag + upsert_agent_from_identity"
```

---

### Task 3: Per-tenant — unified `oauth_credentials` table + schema + context

**Files:**
- Create: `priv/tenant_repo/migrations/20260625131000_create_oauth_credentials.exs`
- Create: `lib/florina/oauth/credential.ex`
- Create: `lib/florina/oauth.ex`
- Test: `test/florina/oauth_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina/oauth_test.exs
defmodule Florina.OAuthTest do
  use Florina.TenantCase, async: true
  alias Florina.{Accounts, OAuth}

  setup do
    {:ok, agent} = Accounts.create_user(%{username: "a@x.com", email: "a@x.com", is_sales_agent: true})
    %{agent: agent}
  end

  test "upsert_calendar_credential inserts then updates the same row", %{agent: agent} do
    {:ok, c1} =
      OAuth.upsert_calendar_credential(agent.id, :google, %{
        email: "a@x.com",
        access_token: "tok1",
        refresh_token: "ref1",
        scopes: ["openid"]
      })

    assert c1.provider == :google
    assert c1.purpose == :agent_calendar
    assert c1.access_token == "tok1"

    {:ok, c2} =
      OAuth.upsert_calendar_credential(agent.id, :google, %{
        email: "a@x.com",
        access_token: "tok2",
        refresh_token: "ref2"
      })

    assert c2.id == c1.id
    assert c2.access_token == "tok2"

    assert OAuth.get_calendar_credential_for_user(agent.id).access_token == "tok2"
  end
end
```

- [ ] **Step 2: Run it — expect FAIL** (`Florina.OAuth` undefined)

Run: `mix test test/florina/oauth_test.exs`

- [ ] **Step 3: Migration (create only — the old table is dropped in Task 6)**

```elixir
# priv/tenant_repo/migrations/20260625131000_create_oauth_credentials.exs
defmodule Florina.Repo.Migrations.CreateOauthCredentials do
  use Ecto.Migration

  def change do
    create table(:oauth_credentials) do
      add :user_id, references(:voice_user, on_delete: :delete_all)
      add :provider, :string, null: false
      add :purpose, :string, null: false, default: "agent_calendar"
      add :email, :string, size: 254
      add :access_token, :binary, null: false
      add :refresh_token, :binary
      add :client_id, :string, size: 255
      add :client_secret, :binary
      add :token_uri, :string, size: 255
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:oauth_credentials, [:user_id])

    create unique_index(:oauth_credentials, [:provider, :purpose, :user_id, :email],
             name: :oauth_credentials_provider_purpose_user_email_index
           )
  end
end
```

- [ ] **Step 4: Schema**

```elixir
# lib/florina/oauth/credential.ex
defmodule Florina.OAuth.Credential do
  @moduledoc """
  Unified OAuth connection record (per tenant) — one row per connected account.
  Replaces the Google-only `voice_googleoauthcredential`. Tagged by `provider`
  (:google | :microsoft) and `purpose` (:agent_calendar | :florina_mailbox).
  `access_token`, `refresh_token`, `client_secret` are Cloak-encrypted (bytea).

  Table: `oauth_credentials`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  @providers [:google, :microsoft]
  @purposes [:agent_calendar, :florina_mailbox]

  schema "oauth_credentials" do
    belongs_to :user, Florina.Accounts.User
    field :provider, Ecto.Enum, values: @providers
    field :purpose, Ecto.Enum, values: @purposes, default: :agent_calendar
    field :email, :string
    field :access_token, Florina.Encrypted.Binary
    field :refresh_token, Florina.Encrypted.Binary
    field :client_id, :string
    field :client_secret, Florina.Encrypted.Binary
    field :token_uri, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    timestamps()
  end

  @required [:provider, :purpose, :access_token]
  @optional [:user_id, :email, :refresh_token, :client_id, :client_secret, :token_uri, :scopes, :expires_at]

  def changeset(cred, attrs) do
    cred
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:purpose, @purposes)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:provider, :purpose, :user_id, :email],
      name: :oauth_credentials_provider_purpose_user_email_index
    )
  end

  def providers, do: @providers
end
```

- [ ] **Step 5: Context**

```elixir
# lib/florina/oauth.ex
defmodule Florina.OAuth do
  @moduledoc "Per-tenant OAuth credential store (agent calendar + future Florina mailbox)."
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.OAuth.Credential

  def get_calendar_credential_for_user(user_id) do
    TenantRepo.get_by(Credential, user_id: user_id, purpose: :agent_calendar)
  end

  def list_calendar_credentials do
    from(c in Credential, where: c.purpose == :agent_calendar) |> TenantRepo.all()
  end

  @doc "Insert or update an agent's calendar credential for a provider (idempotent per user+provider)."
  def upsert_calendar_credential(user_id, provider, attrs) when is_atom(provider) do
    attrs =
      attrs
      |> Map.merge(%{user_id: user_id, provider: provider, purpose: :agent_calendar})

    case TenantRepo.get_by(Credential,
           user_id: user_id,
           provider: provider,
           purpose: :agent_calendar
         ) do
      nil -> %Credential{} |> Credential.changeset(attrs) |> TenantRepo.insert()
      existing -> existing |> Credential.changeset(attrs) |> TenantRepo.update()
    end
  end

  def update_credential(%Credential{} = c, attrs),
    do: c |> Credential.changeset(attrs) |> TenantRepo.update()

  def delete_credential(%Credential{} = c), do: TenantRepo.delete(c)
end
```

- [ ] **Step 6: Run test — expect PASS**

Run: `mix test test/florina/oauth_test.exs`

- [ ] **Step 7: Commit**

```bash
git add priv/tenant_repo/migrations lib/florina/oauth.ex lib/florina/oauth/credential.ex
git commit -m "feat(oauth): unified per-tenant oauth_credentials store"
```

---

### Task 4: Per-tenant — `calendar_events` table + schema + context

**Files:**
- Create: `priv/tenant_repo/migrations/20260625131500_create_calendar_events.exs`
- Create: `lib/florina/calendar/event.ex`
- Create: `lib/florina/calendar_events.ex`
- Test: `test/florina/calendar_events_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina/calendar_events_test.exs
defmodule Florina.CalendarEventsTest do
  use Florina.TenantCase, async: true
  alias Florina.{Accounts, CalendarEvents}

  setup do
    {:ok, agent} = Accounts.create_user(%{username: "a@x.com", email: "a@x.com", is_sales_agent: true})
    %{agent: agent}
  end

  test "upsert_event is idempotent on (user, provider, external_event_id)", %{agent: agent} do
    ev = fn title ->
      %{
        id: "ext-1",
        title: title,
        start_time: ~U[2026-06-25 10:00:00Z],
        end_time: ~U[2026-06-25 11:00:00Z],
        attendees: ["c@client.com"],
        description: "d",
        location: "Room",
        status: "confirmed",
        raw: %{"x" => 1}
      }
    end

    {:ok, _} = CalendarEvents.upsert_event(agent.id, :google, ev.("First"))
    {:ok, _} = CalendarEvents.upsert_event(agent.id, :google, ev.("Renamed"))

    rows = CalendarEvents.list_events_between(~U[2026-06-25 00:00:00Z], ~U[2026-06-25 23:59:59Z])
    assert length(rows) == 1
    assert hd(rows).title == "Renamed"
    assert hd(rows).attendees == [%{"email" => "c@client.com"}]
  end
end
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `mix test test/florina/calendar_events_test.exs`

- [ ] **Step 3: Migration**

```elixir
# priv/tenant_repo/migrations/20260625131500_create_calendar_events.exs
defmodule Florina.Repo.Migrations.CreateCalendarEvents do
  use Ecto.Migration

  def change do
    create table(:calendar_events) do
      add :user_id, references(:voice_user, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :external_event_id, :string, size: 512, null: false
      add :title, :string, size: 1024
      add :description, :text
      add :location, :string, size: 1024
      add :start_time, :utc_datetime, null: false
      add :end_time, :utc_datetime, null: false
      add :attendees, {:array, :map}, null: false, default: []
      add :status, :string, size: 50
      add :raw, :map
      add :synced_at, :utc_datetime
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:calendar_events, [:start_time])

    create unique_index(:calendar_events, [:user_id, :provider, :external_event_id],
             name: :calendar_events_user_provider_extid_index
           )
  end
end
```

- [ ] **Step 4: Schema**

```elixir
# lib/florina/calendar/event.ex
defmodule Florina.Calendar.Event do
  @moduledoc "A synced calendar event (per tenant, per agent). Backs the merged calendar."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]
  @providers [:google, :microsoft]

  schema "calendar_events" do
    belongs_to :user, Florina.Accounts.User
    field :provider, Ecto.Enum, values: @providers
    field :external_event_id, :string
    field :title, :string
    field :description, :string
    field :location, :string
    field :start_time, :utc_datetime
    field :end_time, :utc_datetime
    field :attendees, {:array, :map}, default: []
    field :status, :string
    field :raw, :map
    field :synced_at, :utc_datetime
    timestamps()
  end

  @fields [
    :user_id,
    :provider,
    :external_event_id,
    :title,
    :description,
    :location,
    :start_time,
    :end_time,
    :attendees,
    :status,
    :raw,
    :synced_at
  ]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :provider, :external_event_id, :start_time, :end_time])
    |> unique_constraint([:user_id, :provider, :external_event_id],
      name: :calendar_events_user_provider_extid_index
    )
  end
end
```

- [ ] **Step 5: Context**

```elixir
# lib/florina/calendar_events.ex
defmodule Florina.CalendarEvents do
  @moduledoc "Per-tenant synced calendar events — the merged-calendar source of truth."
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.Calendar.Event

  @doc "Insert or update one normalized provider event (idempotent on user+provider+external id)."
  def upsert_event(user_id, provider, event) when is_atom(provider) do
    attrs = %{
      user_id: user_id,
      provider: provider,
      external_event_id: event.id,
      title: event[:title],
      description: event[:description],
      location: event[:location],
      start_time: trunc_dt(event.start_time),
      end_time: trunc_dt(event.end_time),
      attendees: Enum.map(event[:attendees] || [], &%{"email" => &1}),
      status: event[:status],
      raw: event[:raw],
      synced_at: now()
    }

    case TenantRepo.get_by(Event,
           user_id: user_id,
           provider: provider,
           external_event_id: event.id
         ) do
      nil -> %Event{} |> Event.changeset(attrs) |> TenantRepo.insert()
      existing -> existing |> Event.changeset(attrs) |> TenantRepo.update()
    end
  end

  @doc "All events whose start falls within [from, to], ordered, with the agent preloaded."
  def list_events_between(%DateTime{} = from, %DateTime{} = to) do
    from(e in Event, where: e.start_time >= ^from and e.start_time <= ^to, order_by: e.start_time)
    |> TenantRepo.all()
    |> TenantRepo.preload(:user)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp trunc_dt(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp trunc_dt(other), do: other
end
```

- [ ] **Step 6: Run test — expect PASS**

Run: `mix test test/florina/calendar_events_test.exs`

- [ ] **Step 7: Commit**

```bash
git add priv/tenant_repo/migrations lib/florina/calendar/event.ex lib/florina/calendar_events.ex
git commit -m "feat(calendar): per-tenant calendar_events store for merged view"
```

---

### Task 5: Provider behaviours + dispatcher + shared helpers

**Files:**
- Create: `lib/florina/integrations/oauth_provider.ex`
- Create: `lib/florina/integrations/calendar_provider.ex`
- Create: `lib/florina/integrations/provider.ex`
- Test: `test/florina/integrations/provider_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina/integrations/provider_test.exs
defmodule Florina.Integrations.ProviderTest do
  use ExUnit.Case, async: true
  alias Florina.Integrations.Provider

  test "redirect_uri embeds tenant slug + provider" do
    uri = Provider.redirect_uri("leadder", "google")
    assert String.ends_with?(uri, "/t/leadder/auth/google/callback")
  end

  test "sign_state/verify_state round-trips and is provider-scoped" do
    state = Provider.sign_state(FlorinaWeb.Endpoint, "leadder", :google)
    assert {:ok, %{tenant_slug: "leadder", provider: "google"}} = Provider.verify_state(FlorinaWeb.Endpoint, state)
  end

  test "decode_claims decodes an unsigned JWT payload" do
    payload = %{"email" => "a@b.com", "email_verified" => true} |> Jason.encode!() |> Base.url_encode64(padding: false)
    jwt = "h.#{payload}.s"
    assert {:ok, %{"email" => "a@b.com"}} = Provider.decode_claims(jwt)
  end

  test "impl resolves configured stub in test env" do
    assert Provider.impl(:google) == Florina.Integrations.Providers.Stub
  end
end
```

(The last assertion depends on Task 6 Step setting test config; if running this task before Task 6's config edit, expect that one to fail until then — acceptable, or move config edit earlier. Recommended: apply the `config/test.exs` provider-stub lines from Task 6 Step 6 now.)

- [ ] **Step 2: Run it — expect FAIL** (`Florina.Integrations.Provider` undefined)

Run: `mix test test/florina/integrations/provider_test.exs`

- [ ] **Step 3: Behaviours**

```elixir
# lib/florina/integrations/oauth_provider.ex
defmodule Florina.Integrations.OAuthProvider do
  @moduledoc "Identity + token behaviour for an OAuth/OIDC provider (Google, Microsoft)."
  alias Florina.OAuth.Credential

  @type tokens :: %{
          required(:access_token) => String.t(),
          optional(:refresh_token) => String.t() | nil,
          optional(:expires_in) => integer() | nil,
          optional(:scope) => String.t(),
          optional(:id_token) => String.t() | nil
        }

  @type identity :: %{
          email: String.t() | nil,
          email_verified: boolean(),
          name: String.t() | nil,
          subject: String.t() | nil
        }

  @callback authorize_url(redirect_uri :: String.t(), state :: String.t()) :: String.t()
  @callback exchange_code(code :: String.t(), redirect_uri :: String.t()) ::
              {:ok, tokens} | {:error, term}
  @callback refresh_token(Credential.t()) ::
              {:ok, %{access_token: String.t(), expires_at: DateTime.t() | nil}} | {:error, term}
  @callback fetch_identity(tokens) :: {:ok, identity} | {:error, term}
end
```

```elixir
# lib/florina/integrations/calendar_provider.ex
defmodule Florina.Integrations.CalendarProvider do
  @moduledoc "Read-calendar behaviour. Returns normalized event maps."
  alias Florina.OAuth.Credential

  @callback list_events(Credential.t(), DateTime.t(), DateTime.t()) ::
              {:ok, [map()]} | {:error, term}
end
```

- [ ] **Step 4: Dispatcher + shared helpers**

```elixir
# lib/florina/integrations/provider.ex
defmodule Florina.Integrations.Provider do
  @moduledoc """
  Dispatches to the configured provider implementation by `:google | :microsoft`,
  and holds shared OAuth helpers: callback URI, signed state, JWT-claim decoding,
  and token-freshness/refresh.
  """
  alias Florina.OAuth.Credential

  @registry %{
    google: {:oauth_provider_google, Florina.Integrations.Providers.Google},
    microsoft: {:oauth_provider_microsoft, Florina.Integrations.Providers.Microsoft}
  }

  @state_salt "agent_oauth_state"

  def impl(provider) when is_atom(provider) do
    {key, default} = Map.fetch!(@registry, provider)
    Application.get_env(:florina, key, default)
  end

  def impl(provider) when is_binary(provider), do: impl(String.to_existing_atom(provider))

  def for_credential(%Credential{provider: p}), do: impl(p)

  def supported?(p) when is_atom(p), do: Map.has_key?(@registry, p)

  def sign_state(endpoint_or_conn, tenant_slug, provider) do
    Phoenix.Token.sign(endpoint_or_conn, @state_salt, %{
      tenant_slug: tenant_slug,
      provider: to_string(provider)
    })
  end

  def verify_state(endpoint_or_conn, state, max_age \\ 600) do
    Phoenix.Token.verify(endpoint_or_conn, @state_salt, state, max_age: max_age)
  end

  def redirect_uri(tenant_slug, provider) do
    base =
      System.get_env("OAUTH_REDIRECT_BASE") ||
        Application.get_env(:florina, :oauth_redirect_base) ||
        FlorinaWeb.Endpoint.url()

    base = String.trim_trailing(base, "/")
    "#{base}/t/#{tenant_slug}/auth/#{provider}/callback"
  end

  @doc """
  Decode (NOT cryptographically verify) the claims of an id_token. Safe here:
  the id_token is received directly from the provider's TLS token endpoint
  (authorization-code flow), never through the browser.
  """
  def decode_claims(id_token) when is_binary(id_token) do
    with [_h, payload, _s] <- String.split(id_token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_id_token}
    end
  end

  def decode_claims(_), do: {:error, :invalid_id_token}

  @doc "Return a valid access token for the credential, refreshing if within 60s of expiry."
  def ensure_valid_token(%Credential{} = cred) do
    if token_expired?(cred) do
      case for_credential(cred).refresh_token(cred) do
        {:ok, %{access_token: t}} when is_binary(t) and t != "" -> {:ok, t}
        {:ok, _} -> {:error, :token_refresh_empty}
        {:error, reason} -> {:error, {:token_refresh_failed, reason}}
      end
    else
      {:ok, cred.access_token}
    end
  end

  defp token_expired?(%Credential{expires_at: nil}), do: false

  defp token_expired?(%Credential{expires_at: exp}),
    do: DateTime.compare(DateTime.utc_now(), DateTime.add(exp, -60, :second)) in [:gt, :eq]
end
```

- [ ] **Step 5: Run test — expect PASS** (after Task 6's test config is in place; see note in Step 1)

Run: `mix test test/florina/integrations/provider_test.exs`

- [ ] **Step 6: Commit**

```bash
git add lib/florina/integrations/oauth_provider.ex lib/florina/integrations/calendar_provider.ex lib/florina/integrations/provider.ex
git commit -m "feat(integrations): provider behaviours + dispatcher + oauth helpers"
```

---

### Task 6: Google provider impl + retire the old Google stack

This task replaces `GoogleCalendar` / `GoogleOAuth` / `GoogleOAuthController` / `GoogleOauthCredential` with `Providers.Google` against the new behaviours, repoints `CalendarSync`, swaps config, and drops the old table. Do it as one commit so the tree stays compiling.

**Files:**
- Create: `lib/florina/integrations/providers/google.ex`
- Create: `lib/florina/integrations/providers/stub.ex`
- Create: `priv/tenant_repo/migrations/20260625132000_drop_voice_googleoauthcredential.exs`
- Modify: `lib/florina/workers/calendar_sync.ex`
- Modify: `lib/florina/calendar.ex` (remove credential funcs + GoogleOauthCredential alias; keep watch funcs)
- Modify: `config/config.exs`, `config/test.exs`
- Delete: `lib/florina/integrations/google_calendar.ex`, `lib/florina/integrations/google_calendar_stub.ex`, `lib/florina/integrations/google_oauth.ex`, `lib/florina_web/controllers/google_oauth_controller.ex`, `lib/florina/calendar/google_oauth_credential.ex`
- Modify: `lib/florina_web/router.ex` (remove the two `/calendar/connect` + `/calendar/callback` routes — new routes come in Task 8)
- Test: `test/florina/integrations/providers/google_test.exs`

- [ ] **Step 1: Write the failing test (identity decode + event normalize via stub-free pure paths)**

```elixir
# test/florina/integrations/providers/google_test.exs
defmodule Florina.Integrations.Providers.GoogleTest do
  use ExUnit.Case, async: true
  alias Florina.Integrations.Providers.Google

  test "authorize_url requests calendar.readonly + offline access" do
    url = Google.authorize_url("https://app/t/x/auth/google/callback", "STATE")
    assert url =~ "accounts.google.com"
    assert url =~ "calendar.readonly"
    assert url =~ "access_type=offline"
    assert url =~ "state=STATE"
  end

  test "fetch_identity reads claims from the id_token" do
    payload =
      %{"email" => "j@leadder.com", "email_verified" => true, "name" => "J", "sub" => "1"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert {:ok, %{email: "j@leadder.com", email_verified: true, name: "J", subject: "1"}} =
             Google.fetch_identity(%{id_token: "h.#{payload}.s"})
  end
end
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `mix test test/florina/integrations/providers/google_test.exs`

- [ ] **Step 3: Implement `Providers.Google`**

```elixir
# lib/florina/integrations/providers/google.ex
defmodule Florina.Integrations.Providers.Google do
  @moduledoc "Google OIDC + Calendar implementation of the provider behaviours."
  @behaviour Florina.Integrations.OAuthProvider
  @behaviour Florina.Integrations.CalendarProvider

  alias Florina.OAuth.Credential
  alias Florina.Integrations.Provider

  @auth_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_uri "https://oauth2.googleapis.com/token"
  @calendar_api "https://www.googleapis.com/calendar/v3"
  @scopes ["openid", "email", "profile", "https://www.googleapis.com/auth/calendar.readonly"]

  @impl Florina.Integrations.OAuthProvider
  def authorize_url(redirect_uri, state) do
    params = %{
      "client_id" => client_id(),
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "scope" => Enum.join(@scopes, " "),
      "access_type" => "offline",
      "include_granted_scopes" => "true",
      "prompt" => "consent",
      "state" => state
    }

    @auth_endpoint <> "?" <> URI.encode_query(params)
  end

  @impl Florina.Integrations.OAuthProvider
  def exchange_code(code, redirect_uri) when is_binary(code) and is_binary(redirect_uri) do
    post_token(%{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => client_id(),
      "client_secret" => client_secret()
    })
  end

  def exchange_code(_, _), do: {:error, :invalid_args}

  @impl Florina.Integrations.OAuthProvider
  def refresh_token(%Credential{refresh_token: rt} = cred) when is_binary(rt) and rt != "" do
    case post_token(%{
           "grant_type" => "refresh_token",
           "refresh_token" => rt,
           "client_id" => cred.client_id || client_id(),
           "client_secret" => cred.client_secret || client_secret()
         }) do
      {:ok, t} -> {:ok, %{access_token: t.access_token, expires_at: expires_at(t.expires_in)}}
      err -> err
    end
  end

  def refresh_token(_), do: {:error, :no_refresh_token}

  @impl Florina.Integrations.OAuthProvider
  def fetch_identity(tokens) do
    with {:ok, claims} <- Provider.decode_claims(tokens[:id_token] || tokens["id_token"]) do
      {:ok,
       %{
         email: claims["email"],
         email_verified: claims["email_verified"] == true,
         name: claims["name"],
         subject: claims["sub"]
       }}
    end
  end

  @impl Florina.Integrations.CalendarProvider
  def list_events(%Credential{} = cred, time_min, time_max) do
    with {:ok, token} <- Provider.ensure_valid_token(cred) do
      params = %{
        calendarId: "primary",
        timeMin: DateTime.to_iso8601(time_min),
        timeMax: DateTime.to_iso8601(time_max),
        singleEvents: true,
        orderBy: "startTime"
      }

      case Req.get("#{@calendar_api}/calendars/primary/events",
             headers: bearer(token),
             params: params,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: b}} ->
          {:ok, b |> Map.get("items", []) |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: s, body: b}} ->
          {:error, {:http, s, b}}

        {:error, r} ->
          {:error, r}
      end
    end
  end

  defp post_token(form) do
    case Req.post(@token_uri, form: form, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: b}} ->
        {:ok,
         %{
           access_token: b["access_token"],
           refresh_token: b["refresh_token"],
           expires_in: b["expires_in"],
           scope: b["scope"] || "",
           id_token: b["id_token"]
         }}

      {:ok, %{status: s, body: b}} ->
        {:error, {:http, s, b}}

      {:error, r} ->
        {:error, r}
    end
  end

  defp normalize(item) when is_map(item) do
    if id = item["id"] do
      start_raw = get_in(item, ["start", "dateTime"]) || get_in(item, ["start", "date"])
      end_raw = get_in(item, ["end", "dateTime"]) || get_in(item, ["end", "date"])
      st = parse_dt(start_raw) || DateTime.utc_now()
      en = parse_dt(end_raw) || DateTime.add(st, 3600, :second)

      %{
        id: id,
        title: item["summary"] || "Untitled Meeting",
        start_time: st,
        end_time: en,
        attendees: item |> Map.get("attendees", []) |> Enum.map(& &1["email"]) |> Enum.reject(&is_nil/1),
        description: item["description"] || "",
        location: item["location"],
        status: item["status"] || "confirmed",
        raw: item
      }
    end
  end

  defp normalize(_), do: nil

  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    s = String.replace(s, "Z", "+00:00")

    case DateTime.from_iso8601(s) do
      {:ok, dt, _} ->
        dt

      _ ->
        case Date.from_iso8601(s) do
          {:ok, d} -> DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp bearer(t), do: [{"authorization", "Bearer #{t}"}, {"content-type", "application/json"}]
  defp client_id, do: Application.get_env(:florina, :google_client_id, "")
  defp client_secret, do: Application.get_env(:florina, :google_client_secret, "")
  defp expires_at(nil), do: nil
  defp expires_at(secs), do: DateTime.add(DateTime.utc_now(), secs, :second) |> DateTime.truncate(:second)
end
```

- [ ] **Step 4: Implement the shared test stub (`Providers.Stub`)**

```elixir
# lib/florina/integrations/providers/stub.ex
defmodule Florina.Integrations.Providers.Stub do
  @moduledoc """
  Process-dict-controlled provider stub for tests; used for BOTH the google and
  microsoft config keys. Defaults succeed with an allowed-domain identity.
  """
  @behaviour Florina.Integrations.OAuthProvider
  @behaviour Florina.Integrations.CalendarProvider

  def authorize_url(redirect_uri, state),
    do: "https://stub.test/authorize?redirect_uri=#{URI.encode_www_form(redirect_uri)}&state=#{state}"

  def exchange_code(_code, _redirect_uri) do
    Process.get(
      :oauth_stub_exchange_code,
      {:ok,
       %{
         access_token: "stub_access",
         refresh_token: "stub_refresh",
         expires_in: 3600,
         scope: "openid email",
         id_token: nil
       }}
    )
  end

  def refresh_token(_cred),
    do: Process.get(:oauth_stub_refresh_token, {:ok, %{access_token: "stub_access2", expires_at: nil}})

  def fetch_identity(_tokens) do
    Process.get(
      :oauth_stub_identity,
      {:ok, %{email: "agent@leadder.com", email_verified: true, name: "Agent Stub", subject: "sub-1"}}
    )
  end

  def list_events(_cred, _min, _max), do: Process.get(:oauth_stub_list_events, {:ok, []})

  def set_exchange_code(r), do: Process.put(:oauth_stub_exchange_code, r)
  def set_refresh_token(r), do: Process.put(:oauth_stub_refresh_token, r)
  def set_identity(r), do: Process.put(:oauth_stub_identity, r)
  def set_list_events(r), do: Process.put(:oauth_stub_list_events, r)

  def reset do
    Enum.each(
      [:oauth_stub_exchange_code, :oauth_stub_refresh_token, :oauth_stub_identity, :oauth_stub_list_events],
      &Process.delete/1
    )
  end
end
```

- [ ] **Step 5: Repoint `CalendarSync` to OAuth + Provider dispatch**

In `lib/florina/workers/calendar_sync.ex`:
- Replace `alias Florina.Calendar` with `alias Florina.OAuth` and `alias Florina.Integrations.Provider`.
- Replace the body of `sync_agent/3`'s credential lookup + fetch:

```elixir
  defp sync_agent(agent, today_start, today_end) do
    acc = %{created: 0, updated: 0, skipped: 0, errors: []}

    case OAuth.get_calendar_credential_for_user(agent.id) do
      nil ->
        Logger.debug("[CalendarSync] agent=#{agent.username} has no calendar credential — skip")
        acc

      cred ->
        case Provider.for_credential(cred).list_events(cred, today_start, today_end) do
          {:ok, events} ->
            Enum.reduce(events, acc, fn event, a ->
              case process_event(agent, event) do
                {:created, _} -> %{a | created: a.created + 1}
                {:updated, _} -> %{a | updated: a.updated + 1}
                :skipped -> %{a | skipped: a.skipped + 1}
                {:error, msg} -> %{a | errors: [msg | a.errors]}
              end
            end)

          {:error, reason} ->
            msg = "CalendarSync agent=#{agent.username} fetch error: #{inspect(reason)}"
            Logger.error("[CalendarSync] #{msg}")
            %{acc | errors: [msg]}
        end
    end
  end
```

(Leave `process_event/2` and below unchanged in this task — `calendar_events` writing is added in Task 12.)

- [ ] **Step 6: Swap config keys**

In `config/config.exs`, replace the integration-clients block:

```elixir
# External integration clients (real impls; overridden to stubs in test.exs)
config :florina,
  elevenlabs_client: Florina.Integrations.ElevenLabs,
  oauth_provider_google: Florina.Integrations.Providers.Google,
  oauth_provider_microsoft: Florina.Integrations.Providers.Microsoft,
  pipedrive_client: Florina.Integrations.Pipedrive
```

In `config/test.exs`, replace the stub block:

```elixir
# External integration stubs — no real HTTP calls in tests
config :florina,
  elevenlabs_client: Florina.Integrations.ElevenLabs.Stub,
  oauth_provider_google: Florina.Integrations.Providers.Stub,
  oauth_provider_microsoft: Florina.Integrations.Providers.Stub,
  pipedrive_client: Florina.Integrations.Pipedrive.Stub
```

(Remove the now-dead `google_calendar_client:` lines from both files.)

- [ ] **Step 7: Strip credential functions from `Florina.Calendar`**

Edit `lib/florina/calendar.ex`: remove the `GoogleOauthCredential` alias and the four credential functions (`get_credential_for_user`, `create_credential`, `update_credential`, `delete_credential`). Keep the watch functions and `alias Florina.Calendar.GoogleCalendarWatch`. Resulting header:

```elixir
defmodule Florina.Calendar do
  @moduledoc "Per-tenant Google Calendar push-notification watch channels (`voice_googlecalendarwatch`)."
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.Calendar.GoogleCalendarWatch
  # ... watch functions only ...
end
```

- [ ] **Step 8: Delete the retired modules + drop the old table**

```bash
git rm lib/florina/integrations/google_calendar.ex \
       lib/florina/integrations/google_calendar_stub.ex \
       lib/florina/integrations/google_oauth.ex \
       lib/florina_web/controllers/google_oauth_controller.ex \
       lib/florina/calendar/google_oauth_credential.ex
```

Drop migration:

```elixir
# priv/tenant_repo/migrations/20260625132000_drop_voice_googleoauthcredential.exs
defmodule Florina.Repo.Migrations.DropVoiceGoogleoauthcredential do
  use Ecto.Migration

  def up do
    drop_if_exists table(:voice_googleoauthcredential)
  end

  def down do
    create table(:voice_googleoauthcredential) do
      add :user_id, references(:voice_user, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :refresh_token, :binary, null: false
      add :token_uri, :string, default: "https://oauth2.googleapis.com/token"
      add :client_id, :string, null: false
      add :client_secret, :binary, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_googleoauthcredential, [:user_id])
  end
end
```

- [ ] **Step 9: Remove old Google routes**

In `lib/florina_web/router.ex`, delete the `get "/calendar/connect", GoogleOAuthController, :connect` line (and its scope's now-stale comment) and the entire `/calendar/callback` scope (router lines ~64–73). Leave the rest; new auth routes arrive in Task 8.

- [ ] **Step 10: Update/remove stale local tests, then run the suite**

Search and fix references to the deleted modules in local tests:

Run: `rg -l "GoogleCalendar|GoogleOAuth|GoogleOauthCredential|google_calendar_client|Calendar.get_credential_for_user" test/ lib/`
Expected after fixes: only matches are watch-related or none. Delete/adjust any local test that exercised the removed Google OAuth controller/client.

Run: `mix precommit`
Expected: PASS (compiles warnings-as-errors, formatted, tests green).

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat(integrations): Google provider impl; retire Google-only OAuth stack"
```

---

### Task 7: AgentAuth — session helpers, plugs, on_mount

**Files:**
- Create: `lib/florina_web/agent_auth.ex`
- Test: `test/florina_web/agent_auth_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina_web/agent_auth_test.exs
defmodule FlorinaWeb.AgentAuthTest do
  use FlorinaWeb.ConnCase, async: true
  alias FlorinaWeb.AgentAuth

  test "require_authenticated_agent redirects to tenant login when no current_agent", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.assign(:tenant, %Florina.Tenants.Tenant{slug: "leadder"})
      |> AgentAuth.require_authenticated_agent([])

    assert conn.halted
    assert redirected_to(conn) == "/t/leadder/login"
  end

  test "require_authenticated_agent passes through when current_agent assigned", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.assign(:tenant, %Florina.Tenants.Tenant{slug: "leadder"})
      |> Plug.Conn.assign(:current_agent, %Florina.Accounts.User{id: 1, active: true})
      |> AgentAuth.require_authenticated_agent([])

    refute conn.halted
  end
end
```

- [ ] **Step 2: Run it — expect FAIL** (`FlorinaWeb.AgentAuth` undefined)

Run: `mix test test/florina_web/agent_auth_test.exs`

- [ ] **Step 3: Implement**

```elixir
# lib/florina_web/agent_auth.ex
defmodule FlorinaWeb.AgentAuth do
  @moduledoc """
  Agent (sales-user) auth: session helpers + plugs (controllers) + an on_mount
  hook (LiveView). The agent lives in the *tenant* DB, so all of these run AFTER
  the tenant is pinned (`ResolveTenant` plug for HTTP, `TenantHook` on_mount for
  LiveView).
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  import Phoenix.Component, only: [assign: 3]

  alias Florina.Accounts

  def log_in_agent(conn, agent) do
    conn
    |> configure_session(renew: true)
    |> put_session(:agent_id, agent.id)
    |> redirect(to: "/t/#{conn.assigns.tenant.slug}/calendar")
  end

  def log_out_agent(conn) do
    slug = conn.assigns.tenant.slug

    conn
    |> configure_session(drop: true)
    |> redirect(to: "/t/#{slug}/login")
  end

  @doc "Plug: assign `:current_agent` from the session if valid + active. Never redirects."
  def fetch_current_agent(conn, _opts) do
    agent =
      with id when is_integer(id) <- get_session(conn, :agent_id),
           %Accounts.User{active: true} = a <- Accounts.get_user(id) do
        a
      else
        _ -> nil
      end

    assign(conn, :current_agent, agent)
  end

  @doc "Plug: require an authenticated, active agent or redirect to tenant login."
  def require_authenticated_agent(conn, _opts) do
    if conn.assigns[:current_agent] do
      conn
    else
      conn
      |> redirect(to: "/t/#{conn.assigns.tenant.slug}/login")
      |> halt()
    end
  end

  @doc "LiveView on_mount — assumes the tenant is already pinned (TenantHook ran first)."
  def on_mount(:ensure_authenticated, _params, session, socket) do
    with id when is_integer(id) <- session["agent_id"],
         %Accounts.User{active: true} = agent <- Accounts.get_user(id) do
      {:cont, assign(socket, :current_agent, agent)}
    else
      _ ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/t/#{session["tenant_slug"]}/login")}
    end
  end
end
```

- [ ] **Step 4: Run test — expect PASS**

Run: `mix test test/florina_web/agent_auth_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/florina_web/agent_auth.ex
git commit -m "feat(web): AgentAuth session helpers, plugs, on_mount"
```

---

### Task 8: AuthController + login page + routes (gate + auto-approve)

**Files:**
- Create: `lib/florina_web/controllers/auth_controller.ex`
- Create: `lib/florina_web/controllers/auth_html.ex`
- Create: `lib/florina_web/controllers/auth_html/login.html.heex`
- Modify: `lib/florina_web/router.ex`
- Modify: `lib/florina_web/live/calls_live.ex`, `lib/florina_web/live/tenant_chat_live.ex` (add agent on_mount)
- Test: `test/florina_web/auth_flow_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina_web/auth_flow_test.exs
defmodule FlorinaWeb.AuthFlowTest do
  use FlorinaWeb.TenantConnCase, async: false
  # ^ Use whichever ConnCase variant pins a real tenant DB + sets tenant_slug in
  #   session. If none exists, see note below.
  alias Florina.Integrations.Providers.Stub
  alias Florina.Tenants

  setup do
    Stub.reset()
    Tenants.set_allowed_domains(tenant_slug(), ["leadder.com"])
    :ok
  end

  test "google sign-in with an allowed domain creates an agent and logs in", %{conn: conn} do
    Stub.set_identity({:ok, %{email: "new@leadder.com", email_verified: true, name: "New", subject: "s"}})

    conn = get(conn, "/t/#{tenant_slug()}/auth/google/callback?code=abc&state=#{valid_state()}")

    assert redirected_to(conn) == "/t/#{tenant_slug()}/calendar"
    assert Florina.Accounts.get_user_by_email("new@leadder.com")
  end

  test "sign-in with a non-company domain is rejected, no account created", %{conn: conn} do
    Stub.set_identity({:ok, %{email: "x@gmail.com", email_verified: true, name: "X", subject: "s"}})

    conn = get(conn, "/t/#{tenant_slug()}/auth/google/callback?code=abc&state=#{valid_state()}")

    assert redirected_to(conn) == "/t/#{tenant_slug()}/login"
    refute Florina.Accounts.get_user_by_email("x@gmail.com")
  end

  defp valid_state, do: Florina.Integrations.Provider.sign_state(FlorinaWeb.Endpoint, tenant_slug(), :google)
end
```

> **Test-harness note for the executor:** the callback needs a *real pinned tenant* (it writes to the tenant DB) AND the conn must carry `tenant_slug` in the session. Check `test/support/` for an existing helper that boots a tenant + drives `/t/:slug` requests (the `tenants_retry_test` uses `FlorinaWeb.ConnCase`; the per-tenant calls/chat LiveView tests show the tenant-pinning pattern). Reuse that helper; expose `tenant_slug/0`. If only `Florina.TenantCase` exists for the DB and `ConnCase` for the web, compose them or add a tiny `TenantConnCase` in `test/support` mirroring the existing per-tenant web tests. Tests are git-ignored, so this support file is local-only.

- [ ] **Step 2: Run it — expect FAIL** (route/controller missing)

Run: `mix test test/florina_web/auth_flow_test.exs`

- [ ] **Step 3: Controller**

```elixir
# lib/florina_web/controllers/auth_controller.ex
defmodule FlorinaWeb.AuthController do
  @moduledoc "Agent sign-in via Google/Microsoft: login page, OAuth start, callback, logout."
  use FlorinaWeb, :controller
  require Logger

  alias Florina.{Accounts, OAuth}
  alias Florina.Integrations.Provider
  import FlorinaWeb.AgentAuth, only: [log_in_agent: 2, log_out_agent: 1]

  @providers ~w(google microsoft)

  def login(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:login, tenant: conn.assigns.tenant, error: Phoenix.Flash.get(conn.assigns.flash, :error))
  end

  def start(conn, %{"provider" => provider}) when provider in @providers do
    p = String.to_existing_atom(provider)
    slug = conn.assigns.tenant.slug
    url = Provider.impl(p).authorize_url(Provider.redirect_uri(slug, provider), Provider.sign_state(conn, slug, p))
    redirect(conn, external: url)
  end

  def start(conn, _),
    do: conn |> put_flash(:error, "Unknown sign-in provider.") |> redirect(to: login_path(conn))

  def callback(conn, %{"provider" => provider, "code" => code, "state" => state})
      when provider in @providers do
    p = String.to_existing_atom(provider)
    slug = conn.assigns.tenant.slug

    with {:ok, %{tenant_slug: ^slug, provider: ^provider}} <- Provider.verify_state(conn, state),
         {:ok, tokens} <- Provider.impl(p).exchange_code(code, Provider.redirect_uri(slug, provider)),
         {:ok, identity} <- Provider.impl(p).fetch_identity(tokens),
         :ok <- gate(identity, conn.assigns.tenant),
         {:ok, agent} <- Accounts.upsert_agent_from_identity(identity),
         {:ok, _cred} <- store_credential(agent, p, identity, tokens) do
      log_in_agent(conn, agent)
    else
      {:error, :forbidden_domain} ->
        conn
        |> put_flash(:error, "Please sign in with your company email address.")
        |> redirect(to: login_path(conn))

      {:error, :inactive} ->
        conn
        |> put_flash(:error, "Your account is deactivated. Contact your administrator.")
        |> redirect(to: login_path(conn))

      other ->
        Logger.warning("[AuthController] sign-in failed: #{inspect(other)}")

        conn
        |> put_flash(:error, "Sign-in failed. Please try again.")
        |> redirect(to: login_path(conn))
    end
  end

  def callback(conn, %{"error" => error}) do
    Logger.warning("[AuthController] provider error: #{error}")

    conn
    |> put_flash(:error, "Authorization was cancelled or failed.")
    |> redirect(to: login_path(conn))
  end

  def callback(conn, _),
    do: conn |> put_status(400) |> put_flash(:error, "Invalid callback.") |> redirect(to: login_path(conn))

  def logout(conn, _params), do: log_out_agent(conn)

  # --- helpers ---

  defp login_path(conn), do: "/t/#{conn.assigns.tenant.slug}/login"

  defp gate(%{email: email, email_verified: true}, tenant) when is_binary(email) do
    domain = email |> String.split("@") |> List.last() |> String.downcase()
    allowed = Enum.map(tenant.allowed_email_domains || [], &String.downcase/1)
    if domain in allowed, do: :ok, else: {:error, :forbidden_domain}
  end

  defp gate(_identity, _tenant), do: {:error, :forbidden_domain}

  defp store_credential(agent, provider, identity, tokens) do
    expires_at =
      case tokens[:expires_in] do
        nil -> nil
        s -> DateTime.add(DateTime.utc_now(), s, :second) |> DateTime.truncate(:second)
      end

    OAuth.upsert_calendar_credential(agent.id, provider, %{
      email: identity.email,
      access_token: tokens.access_token,
      refresh_token: tokens[:refresh_token],
      scopes: String.split(tokens[:scope] || "", " ", trim: true),
      expires_at: expires_at
    })
  end
end
```

- [ ] **Step 4: HTML module + login template**

```elixir
# lib/florina_web/controllers/auth_html.ex
defmodule FlorinaWeb.AuthHTML do
  use FlorinaWeb, :html
  embed_templates "auth_html/*"
end
```

```heex
<%!-- lib/florina_web/controllers/auth_html/login.html.heex --%>
<div class="min-h-screen flex items-center justify-center bg-gray-50 px-4">
  <div class="w-full max-w-sm bg-white border rounded-lg p-8 shadow-sm">
    <h1 class="text-xl font-semibold text-center">Sign in to Florina</h1>
    <p class="text-sm text-gray-500 text-center mt-1 mb-6">{@tenant.name}</p>

    <div :if={@error} class="mb-4 rounded bg-red-50 text-red-700 text-sm px-3 py-2">
      {@error}
    </div>

    <a
      href={~p"/t/#{@tenant.slug}/auth/google/start"}
      class="flex items-center justify-center gap-2 w-full border rounded px-4 py-2 text-sm font-medium hover:bg-gray-50"
    >
      Sign in with Google
    </a>
    <%!-- Microsoft button added in Slice 2 (Task 11) --%>

    <p class="text-xs text-gray-400 text-center mt-6">
      Use your company email. Accounts are created automatically.
    </p>
  </div>
</div>
```

- [ ] **Step 5: Routes — add auth scope, gate agent pages, add `agent_auth` pipeline**

In `lib/florina_web/router.ex`, near the top add (after `use FlorinaWeb, :router`):

```elixir
  import FlorinaWeb.AgentAuth, only: [fetch_current_agent: 2, require_authenticated_agent: 2]
```

Add a pipeline:

```elixir
  pipeline :agent_auth do
    plug :fetch_current_agent
    plug :require_authenticated_agent
  end
```

Replace the old agent scope (the one that was `[:browser, :dashboard_auth, :resolve_tenant, :tenant_session]` with `/calls` + `/chat`) with two scopes:

```elixir
  # Per-tenant sign-in (no agent gate — these establish the session)
  scope "/t/:tenant_slug", FlorinaWeb do
    pipe_through [:browser, :resolve_tenant, :tenant_session]
    get "/login", AuthController, :login
    get "/auth/:provider/start", AuthController, :start
    get "/auth/:provider/callback", AuthController, :callback
    delete "/logout", AuthController, :logout
  end

  # Per-tenant agent pages (require an agent session)
  scope "/t/:tenant_slug", FlorinaWeb do
    pipe_through [:browser, :resolve_tenant, :tenant_session, :agent_auth]
    live "/calls", CallsLive
    live "/chat", TenantChatLive
  end
```

- [ ] **Step 6: Add the agent on_mount to the per-tenant LiveViews**

In `lib/florina_web/live/calls_live.ex` and `lib/florina_web/live/tenant_chat_live.ex`, immediately AFTER the existing `on_mount FlorinaWeb.TenantHook` line, add:

```elixir
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
```

- [ ] **Step 7: Run the auth flow test + full suite — expect PASS**

Run: `mix test test/florina_web/auth_flow_test.exs && mix precommit`

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(web): agent sign-in (Google) — login page, callback gate, auto-approve, gated pages"
```

---

### Task 9: Admin UI — manage allowed email domains

**Files:**
- Modify: `lib/florina_web/live/admin/tenants_live.ex`
- Test: `test/florina_web/admin/tenants_domains_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina_web/admin/tenants_domains_test.exs
defmodule FlorinaWeb.Admin.TenantsDomainsTest do
  use FlorinaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Florina.{Admins, Tenants}

  setup do
    Florina.Repo.delete_all(Admins.Admin)
    {:ok, admin} = Admins.create_admin(%{email: "op@x.com", password: "password12"})
    {:ok, _} = Tenants.register(%{slug: "domt", name: "Dom T", database: "florina_tenant_domt"})
    %{conn: init_test_session(build_conn(), %{admin_id: admin.id})}
  end

  test "operator can save allowed domains for a tenant", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin/tenants")

    view
    |> form("#domains-domt", %{"domains" => "Leadder.com, acme.io"})
    |> render_submit()

    assert Tenants.get_by_slug("domt").allowed_email_domains == ["leadder.com", "acme.io"]
  end
end
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `mix test test/florina_web/admin/tenants_domains_test.exs`

- [ ] **Step 3: Add a domains editor to each tenant row**

In `lib/florina_web/live/admin/tenants_live.ex`, add a new column/cell rendering a tiny form per tenant (place it in the Actions cell or a new "Domains" column). Inside the `<tr :for={tenant <- @tenants}>`:

```heex
              <td class="px-4 py-3">
                <form id={"domains-#{tenant.slug}"} phx-submit="save_domains" class="flex gap-1">
                  <input type="hidden" name="slug" value={tenant.slug} />
                  <input
                    type="text"
                    name="domains"
                    value={Enum.join(tenant.allowed_email_domains || [], ", ")}
                    placeholder="leadder.com, acme.io"
                    class="border rounded px-2 py-1 text-xs font-mono w-48"
                  />
                  <button class="text-xs text-blue-600 hover:underline">Save</button>
                </form>
              </td>
```

(Also add a `<th class="px-4 py-3">Domains</th>` header cell and bump the empty-state `colspan` from 6 to 7.)

- [ ] **Step 4: Handle the event**

Add to `tenants_live.ex`:

```elixir
  def handle_event("save_domains", %{"slug" => slug, "domains" => raw}, socket) do
    domains = raw |> String.split([",", " ", "\n"], trim: true)

    case Tenants.set_allowed_domains(slug, domains) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Updated allowed domains for #{slug}.")
         |> assign(:tenants, Tenants.list())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update domains for #{slug}.")}
    end
  end
```

- [ ] **Step 5: (Optional) allow domains at creation** — add a `tenant[allowed_email_domains]` text input to the add-tenant form and include it in `register_attrs` by splitting on commas. Skip if you prefer the per-row editor only.

- [ ] **Step 6: Run test + suite — expect PASS**

Run: `mix test test/florina_web/admin/tenants_domains_test.exs && mix precommit`

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(admin): edit per-tenant allowed email domains"
```

---

**End of Slice 1.** An agent can now sign in with Google at `/t/<slug>/login`, is gated by company email, gets an account + calendar credential, and the existing sync uses that credential. Continue to Slice 2 for Microsoft.

---

# SLICE 2 — Sign in with Microsoft

Adds the Microsoft (Entra ID + Graph) provider against the behaviours from Slice 1. The dispatcher, gate, auto-approve, sessions, routes, and the test stub already handle `:microsoft` — this slice supplies the implementation, the second button, and prod config.

---

### Task 10: Microsoft provider implementation

**Files:**
- Create: `lib/florina/integrations/providers/microsoft.ex`
- Modify: `config/config.exs` (add Microsoft client defaults)
- Test: `test/florina/integrations/providers/microsoft_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina/integrations/providers/microsoft_test.exs
defmodule Florina.Integrations.Providers.MicrosoftTest do
  use ExUnit.Case, async: true
  alias Florina.Integrations.Providers.Microsoft

  test "authorize_url targets the MS identity platform with Calendars.Read + offline_access" do
    url = Microsoft.authorize_url("https://app/t/x/auth/microsoft/callback", "STATE")
    assert url =~ "login.microsoftonline.com"
    assert url =~ "Calendars.Read"
    assert url =~ "offline_access"
    assert url =~ "state=STATE"
  end

  test "fetch_identity prefers email, falls back to preferred_username; work email treated verified" do
    claims = %{"preferred_username" => "j@leadder.com", "name" => "J", "oid" => "o1"}
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)

    assert {:ok, %{email: "j@leadder.com", email_verified: true, name: "J", subject: "o1"}} =
             Microsoft.fetch_identity(%{id_token: "h.#{payload}.s"})
  end
end
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `mix test test/florina/integrations/providers/microsoft_test.exs`

- [ ] **Step 3: Implement `Providers.Microsoft`**

```elixir
# lib/florina/integrations/providers/microsoft.ex
defmodule Florina.Integrations.Providers.Microsoft do
  @moduledoc """
  Microsoft identity platform (Entra ID) + Microsoft Graph Calendar implementation.

  Uses a multi-tenant app by default (`MICROSOFT_TENANT=common`) so agents from
  any customer's Microsoft 365 directory can sign in. Identity comes from the
  id_token claims; calendar from Graph `/me/calendarView`.
  """
  @behaviour Florina.Integrations.OAuthProvider
  @behaviour Florina.Integrations.CalendarProvider

  alias Florina.OAuth.Credential
  alias Florina.Integrations.Provider

  @graph "https://graph.microsoft.com/v1.0"
  @scopes ["openid", "profile", "email", "offline_access", "Calendars.Read"]

  @impl Florina.Integrations.OAuthProvider
  def authorize_url(redirect_uri, state) do
    params = %{
      "client_id" => client_id(),
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "response_mode" => "query",
      "scope" => Enum.join(@scopes, " "),
      "prompt" => "select_account",
      "state" => state
    }

    authorize_endpoint() <> "?" <> URI.encode_query(params)
  end

  @impl Florina.Integrations.OAuthProvider
  def exchange_code(code, redirect_uri) when is_binary(code) and is_binary(redirect_uri) do
    post_token(%{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => client_id(),
      "client_secret" => client_secret(),
      "scope" => Enum.join(@scopes, " ")
    })
  end

  def exchange_code(_, _), do: {:error, :invalid_args}

  @impl Florina.Integrations.OAuthProvider
  def refresh_token(%Credential{refresh_token: rt} = cred) when is_binary(rt) and rt != "" do
    case post_token(%{
           "grant_type" => "refresh_token",
           "refresh_token" => rt,
           "client_id" => cred.client_id || client_id(),
           "client_secret" => cred.client_secret || client_secret(),
           "scope" => Enum.join(@scopes, " ")
         }) do
      {:ok, t} -> {:ok, %{access_token: t.access_token, expires_at: expires_at(t.expires_in)}}
      err -> err
    end
  end

  def refresh_token(_), do: {:error, :no_refresh_token}

  @impl Florina.Integrations.OAuthProvider
  def fetch_identity(tokens) do
    with {:ok, claims} <- Provider.decode_claims(tokens[:id_token] || tokens["id_token"]) do
      email = claims["email"] || claims["preferred_username"]

      {:ok,
       %{
         email: email,
         # Work/school accounts issue org-controlled addresses → treat as verified;
         # the company-domain gate is the real check.
         email_verified: is_binary(email),
         name: claims["name"],
         subject: claims["oid"] || claims["sub"]
       }}
    end
  end

  @impl Florina.Integrations.CalendarProvider
  def list_events(%Credential{} = cred, time_min, time_max) do
    with {:ok, token} <- Provider.ensure_valid_token(cred) do
      params = %{
        "startDateTime" => DateTime.to_iso8601(time_min),
        "endDateTime" => DateTime.to_iso8601(time_max),
        "$orderby" => "start/dateTime",
        "$top" => "250"
      }

      headers = [
        {"authorization", "Bearer #{token}"},
        {"Prefer", ~s(outlook.timezone="UTC")}
      ]

      case Req.get("#{@graph}/me/calendarView",
             headers: headers,
             params: params,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: b}} ->
          {:ok, b |> Map.get("value", []) |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: s, body: b}} ->
          {:error, {:http, s, b}}

        {:error, r} ->
          {:error, r}
      end
    end
  end

  # --- helpers ---

  defp tenant,
    do: Application.get_env(:florina, :microsoft_tenant) || System.get_env("MICROSOFT_TENANT") || "common"

  defp authorize_endpoint, do: "https://login.microsoftonline.com/#{tenant()}/oauth2/v2.0/authorize"
  defp token_endpoint, do: "https://login.microsoftonline.com/#{tenant()}/oauth2/v2.0/token"
  defp client_id, do: Application.get_env(:florina, :microsoft_client_id, "")
  defp client_secret, do: Application.get_env(:florina, :microsoft_client_secret, "")

  defp post_token(form) do
    case Req.post(token_endpoint(), form: form, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: b}} ->
        {:ok,
         %{
           access_token: b["access_token"],
           refresh_token: b["refresh_token"],
           expires_in: b["expires_in"],
           scope: b["scope"] || "",
           id_token: b["id_token"]
         }}

      {:ok, %{status: s, body: b}} ->
        {:error, {:http, s, b}}

      {:error, r} ->
        {:error, r}
    end
  end

  defp normalize(item) when is_map(item) do
    if id = item["id"] do
      st = parse_dt(get_in(item, ["start", "dateTime"])) || DateTime.utc_now()
      en = parse_dt(get_in(item, ["end", "dateTime"])) || DateTime.add(st, 3600, :second)

      attendees =
        item
        |> Map.get("attendees", [])
        |> Enum.map(&get_in(&1, ["emailAddress", "address"]))
        |> Enum.reject(&is_nil/1)

      %{
        id: id,
        title: item["subject"] || "Untitled Meeting",
        start_time: st,
        end_time: en,
        attendees: attendees,
        description: item["bodyPreview"] || "",
        location: get_in(item, ["location", "displayName"]),
        status: if(item["isCancelled"], do: "cancelled", else: "confirmed"),
        raw: item
      }
    end
  end

  defp normalize(_), do: nil

  # Graph returns e.g. "2026-06-25T10:00:00.0000000" (UTC, per the Prefer header), no offset.
  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    case NaiveDateTime.from_iso8601(String.slice(s, 0, 19)) do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  defp expires_at(nil), do: nil
  defp expires_at(secs), do: DateTime.add(DateTime.utc_now(), secs, :second) |> DateTime.truncate(:second)
end
```

- [ ] **Step 4: Config defaults**

In `config/config.exs`, add a Microsoft block next to the Google one:

```elixir
# Microsoft (Entra ID) OAuth — global client credentials (set in runtime.exs for prod)
config :florina,
  microsoft_client_id: nil,
  microsoft_client_secret: nil,
  microsoft_tenant: "common"
```

And in `config/test.exs`, add placeholder keys next to the google ones:

```elixir
  microsoft_client_id: nil,
  microsoft_client_secret: nil,
```

- [ ] **Step 5: Run test + suite — expect PASS**

Run: `mix test test/florina/integrations/providers/microsoft_test.exs && mix precommit`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(integrations): Microsoft (Entra + Graph) provider implementation"
```

---

### Task 11: Microsoft sign-in button + production config

**Files:**
- Modify: `lib/florina_web/controllers/auth_html/login.html.heex`
- Modify: `config/runtime.exs`
- Test: extend `test/florina_web/auth_flow_test.exs`

- [ ] **Step 1: Add a failing test for the Microsoft callback path**

Append to `test/florina_web/auth_flow_test.exs`:

```elixir
  test "microsoft sign-in with an allowed domain logs in", %{conn: conn} do
    Florina.Integrations.Providers.Stub.set_identity(
      {:ok, %{email: "ms@leadder.com", email_verified: true, name: "Ms", subject: "o"}}
    )

    state = Florina.Integrations.Provider.sign_state(FlorinaWeb.Endpoint, tenant_slug(), :microsoft)
    conn = get(conn, "/t/#{tenant_slug()}/auth/microsoft/callback?code=abc&state=#{state}")

    assert redirected_to(conn) == "/t/#{tenant_slug()}/calendar"
    assert Florina.Accounts.get_user_by_email("ms@leadder.com")
  end
```

- [ ] **Step 2: Run it — expect PASS already** (the dispatcher + stub already handle `:microsoft`; this test confirms it). If it fails, fix the provider wiring before continuing.

Run: `mix test test/florina_web/auth_flow_test.exs`

- [ ] **Step 3: Add the Microsoft button to the login page**

In `login.html.heex`, replace the `<%!-- Microsoft button added in Slice 2 --%>` comment with:

```heex
    <a
      href={~p"/t/#{@tenant.slug}/auth/microsoft/start"}
      class="flex items-center justify-center gap-2 w-full border rounded px-4 py-2 text-sm font-medium hover:bg-gray-50 mt-3"
    >
      Sign in with Microsoft
    </a>
```

- [ ] **Step 4: Production env wiring**

In `config/runtime.exs`, inside the `if config_env() == :prod do` block, immediately after the existing Google block:

```elixir
  config :florina,
    google_client_id: System.get_env("GOOGLE_CLIENT_ID"),
    google_client_secret: System.get_env("GOOGLE_CLIENT_SECRET")
```

add:

```elixir
  config :florina,
    microsoft_client_id: System.get_env("MICROSOFT_CLIENT_ID"),
    microsoft_client_secret: System.get_env("MICROSOFT_CLIENT_SECRET"),
    microsoft_tenant: System.get_env("MICROSOFT_TENANT") || "common"

  # Shared OAuth callback base (falls back to PHX_HOST endpoint URL). Set if the
  # public callback host differs from PHX_HOST.
  if base = System.get_env("OAUTH_REDIRECT_BASE") do
    config :florina, :oauth_redirect_base, base
  end
```

- [ ] **Step 5: Run suite — expect PASS**

Run: `mix precommit`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(web): Microsoft sign-in button + prod OAuth config"
```

---

**End of Slice 2.** Agents can sign in with Google or Microsoft. Both store a unified credential; the sync already reads either via the dispatcher.

---

# SLICE 3 — Merged calendar

Makes the 30-min sync record **every** agent's events into `calendar_events` (not only client-matched ones), then renders a single merged week view of all agents.

---

### Task 12: Sync records all events into `calendar_events`

**Files:**
- Modify: `lib/florina/workers/calendar_sync.ex`
- Test: `test/florina/workers/calendar_sync_merged_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina/workers/calendar_sync_merged_test.exs
defmodule Florina.Workers.CalendarSyncMergedTest do
  use Florina.TenantCase, async: false
  alias Florina.{Accounts, OAuth, CalendarEvents}
  alias Florina.Integrations.Providers.Stub
  alias Florina.Workers.CalendarSync

  setup do
    Stub.reset()
    {:ok, agent} = Accounts.create_user(%{username: "a@leadder.com", email: "a@leadder.com", is_sales_agent: true})
    {:ok, _} = OAuth.upsert_calendar_credential(agent.id, :google, %{email: "a@leadder.com", access_token: "t"})
    %{agent: agent}
  end

  test "every fetched event is recorded in calendar_events, even with no client match", %{agent: agent} do
    Stub.set_list_events(
      {:ok,
       [
         %{
           id: "evt-x",
           title: "Internal sync",
           start_time: DateTime.utc_now(),
           end_time: DateTime.add(DateTime.utc_now(), 3600, :second),
           attendees: ["nobody@unknown.com"],
           description: "",
           location: nil,
           status: "confirmed",
           raw: %{}
         }
       ]}
    )

    assert :ok = perform_job(CalendarSync, %{"tenant_slug" => tenant_slug()})

    day = Date.utc_today()
    from = DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(day, ~T[23:59:59], "Etc/UTC")
    assert [%{external_event_id: "evt-x"}] = CalendarEvents.list_events_between(from, to)
  end
end
```

(`perform_job/2` + `tenant_slug/0` come from `Florina.TenantCase` / `Oban.Testing`; match how existing worker tests invoke jobs.)

- [ ] **Step 2: Run it — expect FAIL** (no row recorded)

Run: `mix test test/florina/workers/calendar_sync_merged_test.exs`

- [ ] **Step 3: Record events during sync**

In `lib/florina/workers/calendar_sync.ex`:
- Add `alias Florina.CalendarEvents`.
- In `sync_agent/3`, inside the `{:ok, events} ->` branch, record every event BEFORE the visit-derivation reduce:

```elixir
          {:ok, events} ->
            Enum.each(events, fn ev ->
              case CalendarEvents.upsert_event(agent.id, cred.provider, ev) do
                {:ok, _} -> :ok
                {:error, cs} -> Logger.warning("[CalendarSync] event upsert failed: #{inspect(cs.errors)}")
              end
            end)

            Enum.reduce(events, acc, fn event, a ->
              case process_event(agent, event) do
                {:created, _} -> %{a | created: a.created + 1}
                {:updated, _} -> %{a | updated: a.updated + 1}
                :skipped -> %{a | skipped: a.skipped + 1}
                {:error, msg} -> %{a | errors: [msg | a.errors]}
              end
            end)
```

(`cred` is already in scope in `sync_agent/3` from Task 6.)

- [ ] **Step 4: Run test + suite — expect PASS**

Run: `mix test test/florina/workers/calendar_sync_merged_test.exs && mix precommit`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): record all agent events into calendar_events (merged source)"
```

---

### Task 13: Merged calendar LiveView

**Files:**
- Create: `lib/florina_web/live/calendar_live.ex`
- Modify: `lib/florina_web/router.ex` (add `live "/calendar", CalendarLive` to the agent-gated scope)
- Test: `test/florina_web/live/calendar_live_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/florina_web/live/calendar_live_test.exs
# Uses the same per-tenant web harness as the auth flow test (TenantConnCase),
# with an agent already logged in (agent_id in session).
defmodule FlorinaWeb.CalendarLiveTest do
  use FlorinaWeb.TenantConnCase, async: false
  import Phoenix.LiveViewTest
  alias Florina.{Accounts, CalendarEvents}

  test "renders this week's events from all agents", %{conn: conn} do
    {:ok, a1} = Accounts.create_user(%{username: "a1@leadder.com", email: "a1@leadder.com", is_sales_agent: true})
    {:ok, a2} = Accounts.create_user(%{username: "a2@leadder.com", email: "a2@leadder.com", is_sales_agent: true})

    today = Date.utc_today()
    at = fn h -> DateTime.new!(today, Time.new!(h, 0, 0), "Etc/UTC") end

    {:ok, _} = CalendarEvents.upsert_event(a1.id, :google, ev("Alpha meeting", at.(9), at.(10)))
    {:ok, _} = CalendarEvents.upsert_event(a2.id, :microsoft, ev("Beta meeting", at.(11), at.(12)))

    conn = login_agent(conn, a1)
    {:ok, _view, html} = live(conn, "/t/#{tenant_slug()}/calendar")

    assert html =~ "Alpha meeting"
    assert html =~ "Beta meeting"
  end

  defp ev(title, s, e),
    do: %{id: "x-#{title}", title: title, start_time: s, end_time: e, attendees: [], description: "", location: nil, status: "confirmed", raw: %{}}
end
```

(`login_agent/2` puts `agent_id` in the session — add it to the test harness like `tenants_retry_test` sets `admin_id`.)

- [ ] **Step 2: Run it — expect FAIL**

Run: `mix test test/florina_web/live/calendar_live_test.exs`

- [ ] **Step 3: Implement the LiveView**

```elixir
# lib/florina_web/live/calendar_live.ex
defmodule FlorinaWeb.CalendarLive do
  @moduledoc "Merged calendar: every agent's appointments for a week, filterable by agent."
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}

  alias Florina.{Accounts, CalendarEvents}

  @impl true
  def mount(_params, _session, socket) do
    monday = week_monday(Date.utc_today())

    {:ok,
     socket
     |> assign(:agents, Accounts.list_agents())
     |> assign(:filter_agent_id, nil)
     |> load_week(monday)}
  end

  @impl true
  def handle_event("filter", %{"agent_id" => id}, socket) do
    {:noreply, assign(socket, :filter_agent_id, parse_id(id))}
  end

  def handle_event("prev_week", _params, socket),
    do: {:noreply, load_week(socket, Date.add(socket.assigns.monday, -7))}

  def handle_event("next_week", _params, socket),
    do: {:noreply, load_week(socket, Date.add(socket.assigns.monday, 7))}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-4 py-6 max-w-6xl mx-auto">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-semibold">Calendar</h1>
        <div class="flex items-center gap-2">
          <form phx-change="filter">
            <select name="agent_id" class="border rounded px-2 py-1 text-sm">
              <option value="">All agents</option>
              <option :for={a <- @agents} value={a.id} selected={@filter_agent_id == a.id}>
                {agent_label(a)}
              </option>
            </select>
          </form>
          <button phx-click="prev_week" class="px-2 py-1 text-sm border rounded hover:bg-gray-50">←</button>
          <span class="text-sm text-gray-600">{week_range_label(@monday)}</span>
          <button phx-click="next_week" class="px-2 py-1 text-sm border rounded hover:bg-gray-50">→</button>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-7 gap-3">
        <div :for={day <- @days} class="border rounded-lg p-2 min-h-32">
          <div class="text-xs font-medium text-gray-500 mb-2">
            {Calendar.strftime(day, "%a %d %b")}
          </div>
          <div class="space-y-1">
            <div
              :for={ev <- events_for(@events, day, @filter_agent_id)}
              class="rounded px-2 py-1 text-xs bg-blue-50 border border-blue-100"
            >
              <div class="font-medium text-gray-800">{format_time(ev.start_time)} · {ev.title}</div>
              <div class="text-gray-500">{agent_label(ev.user)}</div>
            </div>
            <p :if={events_for(@events, day, @filter_agent_id) == []} class="text-xs text-gray-300">—</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- data ---

  defp load_week(socket, monday) do
    from = DateTime.new!(monday, ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(Date.add(monday, 6), ~T[23:59:59], "Etc/UTC")

    socket
    |> assign(:monday, monday)
    |> assign(:days, Enum.map(0..6, &Date.add(monday, &1)))
    |> assign(:events, CalendarEvents.list_events_between(from, to))
  end

  defp events_for(events, day, filter) do
    events
    |> Enum.filter(fn e -> DateTime.to_date(e.start_time) == day end)
    |> Enum.filter(fn e -> is_nil(filter) or e.user_id == filter end)
  end

  # --- helpers ---

  defp week_monday(date), do: Date.add(date, -(Date.day_of_week(date) - 1))

  defp week_range_label(monday),
    do: "#{Calendar.strftime(monday, "%d %b")} – #{Calendar.strftime(Date.add(monday, 6), "%d %b")}"

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

  defp agent_label(nil), do: "—"

  defp agent_label(user) do
    name = [user.first_name, user.last_name] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
    if name == "", do: user.email || user.username, else: name
  end

  defp parse_id(""), do: nil
  defp parse_id(id), do: String.to_integer(id)
end
```

- [ ] **Step 4: Route**

In `lib/florina_web/router.ex`, add to the agent-gated `/t/:tenant_slug` scope (alongside `/calls`, `/chat`):

```elixir
    live "/calendar", CalendarLive
```

- [ ] **Step 5: Run test + suite — expect PASS**

Run: `mix test test/florina_web/live/calendar_live_test.exs && mix precommit`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(web): merged all-agents calendar view"
```

---

**End of Slice 3 / Phase 1.** Agents sign in with Google or Microsoft, are gated by company email, auto-approved, calendar connected; all events sync into `calendar_events`; the merged calendar shows everyone.

---

## Post-implementation (operator, manual — not code)

1. **Register the OAuth apps** (central model): a Google Cloud OAuth client (with calendar.readonly scope; submit for verification) and a multi-tenant Azure/Entra app (Calendars.Read delegated). Set redirect URIs to `https://<host>/t/<slug>/auth/google/callback` and `.../microsoft/callback` — Google/Azure allow path-varying redirect URIs per registered host; if a customer needs a fixed slug, register that exact URI.
2. **Set env vars** on Railway: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET`, optionally `MICROSOFT_TENANT`, `OAUTH_REDIRECT_BASE`.
3. **Migrate existing tenants:** `bin/florina rpc 'Florina.Release.migrate_tenants()'` (adds `oauth_credentials`, `calendar_events`, `active`; drops the old table).
4. **Set allowed domains** for each tenant in `/admin/tenants` (e.g. leadder → `leadder.com`).
5. Give each company its login URL: `https://<host>/t/<slug>/login`.

---

## Self-Review

**Spec coverage:**
- ✅ Provider switch (behaviours + dispatcher) — Task 5; Google Task 6; Microsoft Task 10.
- ✅ Unified `oauth_credentials` replacing the Google table — Tasks 3, 6.
- ✅ `calendar_events` synced copy — Tasks 4, 12.
- ✅ Agent logins (`AgentAuth`, routes) replacing shared password on agent pages — Tasks 7, 8.
- ✅ Company-email gate (verified email AND domain) + auto-approve — Task 8 (`gate/2`, `upsert_agent_from_identity`).
- ✅ Per-tenant allowed domains, operator-managed — Tasks 1, 9.
- ✅ Agent `active` deactivation lever — Tasks 2, 7, 8.
- ✅ Merged calendar view — Task 13.
- ✅ Central app default + per-customer fallback (`client_id`/`client_secret` on credential) — schema Task 3; Post-impl notes.
- ⏭️ Florina mailbox (Phase 2) — intentionally out of this plan.
- ⏭️ Push/watch real-time — intentionally out (cron drives sync).

**Type/name consistency checks:**
- `Provider.impl/1`, `Provider.for_credential/1`, `Provider.sign_state/3`, `Provider.verify_state/2,3`, `Provider.redirect_uri/2`, `Provider.decode_claims/1`, `Provider.ensure_valid_token/1` — used identically in Tasks 6, 8, 10.
- Provider impls implement `authorize_url/2`, `exchange_code/2`, `refresh_token/1`, `fetch_identity/1`, `list_events/3` — consistent across Google (Task 6) + Microsoft (Task 10) + Stub (Task 6) + behaviours (Task 5).
- `OAuth.upsert_calendar_credential/3` and `get_calendar_credential_for_user/1` — defined Task 3, used Tasks 8, 12.
- `Accounts.upsert_agent_from_identity/1`, `get_user_by_email/1` — defined Task 2, used Task 8.
- `CalendarEvents.upsert_event/3`, `list_events_between/2` — defined Task 4, used Tasks 12, 13.
- `Tenants.set_allowed_domains/2` — defined Task 1, used Task 9.
- on_mount order `TenantHook` → `{AgentAuth, :ensure_authenticated}` — Tasks 8, 13.

**Known executor watch-outs (no placeholders, just sequencing):**
- Task 6 is a wide swap; keep all sub-steps in one commit so the tree compiles. The `rg` reference sweep (Task 6 Step 10) catches stragglers.
- The web tests for the OAuth callback and calendar need a tenant-pinning ConnCase helper. Reuse the existing per-tenant web test pattern (calls/chat LiveView tests); the note in Task 8 Step 1 explains how. All such test support is git-ignored.
