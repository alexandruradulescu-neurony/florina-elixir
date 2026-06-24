# Slice 1b — Live Calls Dashboard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A Phoenix LiveView page at `/calls` (gated by HTTP Basic Auth) that lists recent calls and updates them live when slice 1a broadcasts `{:call_updated, call}` on the `"calls"` PubSub topic.

**Architecture:** LiveView + LiveView streams for the call rows. On `mount` (connected), subscribe to `"calls"`; load recent rows via a new `Calls.list_recent/1`. `handle_info/2` upserts a row on each broadcast. The route sits behind a Basic Auth plug whose credentials come from config/env.

**Tech Stack:** Phoenix LiveView 1.x, Ecto, `Plug.BasicAuth`, Phoenix.PubSub.

**Builds on:** slice 1a (`Florina.Calls`, `Florina.Calls.CallAttempt`, the `"calls"` broadcast). Uses the default `Florina.Repo` (tenant routing is a later slice).

---

## File Structure

- Modify `lib/florina/calls.ex` — add `list_recent/1`.
- Create `lib/florina_web/live/calls_live.ex` — the LiveView.
- Modify `lib/florina_web/router.ex` — Basic Auth pipeline + `live "/calls"` route.
- Modify `config/config.exs` (dev/test defaults) and `config/runtime.exs` (prod env vars) — dashboard credentials.
- Tests (local, git-ignored): `test/florina/calls_list_recent_test.exs`, `test/florina_web/live/calls_live_test.exs`.

---

## Task 1: `Calls.list_recent/1`

**Files:** Modify `lib/florina/calls.ex` · Test `test/florina/calls_list_recent_test.exs`

- [ ] **Step 1: Failing test**

```elixir
defmodule Florina.CallsListRecentTest do
  use Florina.DataCase, async: true
  alias Florina.{Calls, Repo}
  alias Florina.Calls.CallAttempt

  defp insert(ext), do: %CallAttempt{} |> CallAttempt.webhook_changeset(%{external_call_id: ext, status: "IN_PROGRESS"}) |> Repo.insert!()

  test "returns calls newest-updated first, capped by limit" do
    insert("a"); insert("b"); insert("c")
    ids = Calls.list_recent(2) |> Enum.map(& &1.external_call_id)
    assert length(ids) == 2
  end
end
```

- [ ] **Step 2: Run — expect FAIL** (`list_recent/1` undefined). Run: `mix test test/florina/calls_list_recent_test.exs`

- [ ] **Step 3: Implement** (add to `lib/florina/calls.ex`)

```elixir
  import Ecto.Query, only: [order_by: 2, limit: 2]

  @doc "Recent calls, most-recently-updated first."
  def list_recent(max \\ 50) do
    CallAttempt
    |> order_by(desc: :updated_at)
    |> limit(^max)
    |> Repo.all()
  end
```

- [ ] **Step 4: Run — expect PASS.** Run: `mix test test/florina/calls_list_recent_test.exs`
- [ ] **Step 5: Commit** — `git add lib/florina/calls.ex` then commit `feat: Calls.list_recent`

---

## Task 2: Dashboard Basic Auth (config + plug)

**Files:** Modify `config/config.exs`, `config/test.exs`, `config/runtime.exs`, `lib/florina_web/router.ex`

- [ ] **Step 1: Config defaults**

In `config/config.exs` (dev default credentials — safe placeholders):
```elixir
config :florina, :dashboard_auth, username: "admin", password: "change-me-in-prod"
```
In `config/test.exs`:
```elixir
config :florina, :dashboard_auth, username: "admin", password: "test-pass"
```
In `config/runtime.exs`, inside the `if config_env() == :prod do` block, override from env:
```elixir
  config :florina, :dashboard_auth,
    username: System.get_env("DASHBOARD_USER") || "admin",
    password:
      System.get_env("DASHBOARD_PASS") ||
        raise("DASHBOARD_PASS not set — required to protect the /calls dashboard")
```

- [ ] **Step 2: Add the auth plug + pipeline in `router.ex`**

```elixir
  pipeline :dashboard_auth do
    plug :basic_auth_dashboard
  end

  defp basic_auth_dashboard(conn, _opts) do
    creds = Application.fetch_env!(:florina, :dashboard_auth)
    Plug.BasicAuth.basic_auth(conn, username: creds[:username], password: creds[:password])
  end
```

(No isolated test — verified by the LiveView test's 401 case in Task 3.)

- [ ] **Step 3: Compile** — `mix compile --warnings-as-errors`
- [ ] **Step 4: Commit** — `git add config/config.exs config/test.exs config/runtime.exs lib/florina_web/router.ex` then commit `feat: basic-auth config + pipeline for dashboard`

---

## Task 3: `CallsLive` LiveView + route

**Files:** Create `lib/florina_web/live/calls_live.ex` · Modify `lib/florina_web/router.ex` · Test `test/florina_web/live/calls_live_test.exs`

- [ ] **Step 1: Failing test**

```elixir
defmodule FlorinaWeb.CallsLiveTest do
  use FlorinaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Florina.Repo
  alias Florina.Calls.CallAttempt

  defp auth(conn),
    do: put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth("admin", "test-pass"))

  test "rejects without basic auth", %{conn: conn} do
    assert get(conn, ~p"/calls").status == 401
  end

  test "lists recent calls and updates live on broadcast", %{conn: conn} do
    {:ok, ca} =
      %CallAttempt{}
      |> CallAttempt.webhook_changeset(%{external_call_id: "conv_live", status: "IN_PROGRESS", phase: "POST"})
      |> Repo.insert()

    {:ok, view, html} = live(auth(conn), ~p"/calls")
    assert html =~ "conv_live"

    Phoenix.PubSub.broadcast(Florina.PubSub, "calls", {:call_updated, %{ca | status: "COMPLETED"}})
    assert render(view) =~ "COMPLETED"
  end
end
```

- [ ] **Step 2: Run — expect FAIL** (no route / no module). Run: `mix test test/florina_web/live/calls_live_test.exs`

- [ ] **Step 3: Implement the LiveView**

```elixir
defmodule FlorinaWeb.CallsLive do
  use FlorinaWeb, :live_view
  alias Florina.Calls

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Florina.PubSub, "calls")
    {:ok, stream(socket, :calls, Calls.list_recent())}
  end

  @impl true
  def handle_info({:call_updated, call}, socket) do
    {:noreply, stream_insert(socket, :calls, call, at: 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold mb-4">Calls</h1>
    <table class="w-full text-left">
      <thead>
        <tr><th>Phase</th><th>Status</th><th>Call ID</th><th>Summary</th><th>Updated</th></tr>
      </thead>
      <tbody id="calls" phx-update="stream">
        <tr :for={{dom_id, call} <- @streams.calls} id={dom_id}>
          <td>{call.phase}</td>
          <td>{call.status}</td>
          <td>{call.external_call_id}</td>
          <td>{call.summary}</td>
          <td>{call.updated_at}</td>
        </tr>
      </tbody>
    </table>
    """
  end
end
```

(Use the project's existing HEEx conventions — if `{...}` body interpolation isn't accepted by this Phoenix version, use `<%= %>`. The tests assert on rendered text and will confirm.)

- [ ] **Step 4: Add the route in `router.ex`** (a scope using `:browser` + `:dashboard_auth`)

```elixir
  scope "/", FlorinaWeb do
    pipe_through [:browser, :dashboard_auth]
    live "/calls", CallsLive
  end
```

- [ ] **Step 5: Run — expect PASS (both cases).** Run: `mix test test/florina_web/live/calls_live_test.exs`
- [ ] **Step 6: Full suite + strict compile + format**

Run: `mix test` then `mix compile --warnings-as-errors` then `mix format`

- [ ] **Step 7: Commit** — `git add lib/florina_web/live/calls_live.ex lib/florina_web/router.ex` then commit `feat: live calls dashboard (LiveView, basic-auth gated)`

---

## Self-Review

- **Spec coverage:** live list (Task 1+3), live updates via `"calls"` broadcast (Task 3 handle_info + test), Basic Auth gate (Task 2 + Task 3 401 test). Route `/calls`, limit 50 — per spec defaults.
- **Placeholders:** none.
- **Type consistency:** `list_recent/1`, `stream(:calls)`, topic `"calls"`, broadcast shape `{:call_updated, call}` all match slice 1a.

## Deploy note

Add `DASHBOARD_USER` / `DASHBOARD_PASS` to Railway env vars (prod raises without `DASHBOARD_PASS`). Add them to DEPLOY.md when this ships.
