# Slice 1a — ElevenLabs Webhook Ingestion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phoenix receives ElevenLabs post-call webhooks, verifies the signature (fail-closed), updates the existing `voice_callattempt` row with transcript/summary/status, and broadcasts the change for a future live dashboard.

**Architecture:** Thin real-time edge over the shared database (see the [slice spec](../specs/2026-06-24-voice-call-realtime-edge-slice-design.md)). Phoenix maps Django's existing `voice_callattempt` table with an Ecto schema and writes to it directly; Django remains the system of record. This first plan uses the single default `Florina.Repo`; **per-tenant database routing is a separate follow-up plan** — do not add dynamic repos here.

**Tech Stack:** Phoenix 1.8, Ecto/Postgres, `:crypto`/`Plug.Crypto` for HMAC, Phoenix.PubSub for broadcast.

**Scope guard:** This plan is webhook ingestion only. NOT in this plan: Twilio webhook, the LiveView dashboard, tenant resolution. They are listed at the end as follow-ups.

---

## Shared-schema note (read first)

Phoenix maps a table Django owns. The migration in Task 1 exists **only so local dev/test has the table**; in production the table is created and migrated by Django. The migration module name carries `DevMirror` to make that explicit. Never run Phoenix migrations against a production tenant database.

Column/enum facts (read from the live Django code, commit `fe2f5fa`):
- Table: `voice_callattempt`
- `external_call_id` (varchar, nullable) — the ElevenLabs `conversation_id`
- `status` (varchar) — one of `SCHEDULED, INITIATED, IN_PROGRESS, COMPLETED, NO_ANSWER, FAILED`
- `phase` (varchar) — `PRE` or `POST`
- `transcript`, `summary` (text, nullable), `summary_title` (varchar, nullable)
- `analysis` (jsonb, default `{}`)
- `visit_id` (bigint, nullable), `created_at`, `updated_at` (timestamptz)

ElevenLabs signature (from `voice/webhook_security.py`): header `ElevenLabs-Signature: t=<unix>,v0=<hex>`; HMAC-SHA256 over the bytes `"<t>." <> raw_body`; reject if older than 30 min; fail closed when no secret is configured.

---

## File Structure

- Create `priv/repo/migrations/<ts>_create_voice_callattempt_dev_mirror.exs` — local dev/test table.
- Create `lib/florina/calls/call_attempt.ex` — Ecto schema for `voice_callattempt`.
- Create `lib/florina/calls.ex` — context: lookup + apply-webhook (+ status mapping, broadcast).
- Create `lib/florina/integrations/eleven_labs_signature.ex` — HMAC verification.
- Create `lib/florina_web/raw_body_reader.ex` — caches the raw request body for signing.
- Modify `lib/florina_web/endpoint.ex` — use the raw-body reader in `Plug.Parsers`.
- Create `lib/florina_web/controllers/webhook/eleven_labs_controller.ex` — the endpoint.
- Modify `lib/florina_web/router.ex` — `:webhook` pipeline + route.
- Modify `config/runtime.exs` — read `ELEVENLABS_WEBHOOK_SECRET` from env.
- Tests (local, git-ignored): one per module below.

---

## Task 1: Dev/test mirror of `voice_callattempt`

**Files:** Create `priv/repo/migrations/<ts>_create_voice_callattempt_dev_mirror.exs`

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration create_voice_callattempt_dev_mirror`

- [ ] **Step 2: Fill it in** (replace the generated body)

```elixir
defmodule Florina.Repo.Migrations.CreateVoiceCallattemptDevMirror do
  # DEV/TEST ONLY. In production the `voice_callattempt` table is owned and
  # migrated by Django. This mirror exists so local dev/test has the table.
  use Ecto.Migration

  def change do
    create_if_not_exists table(:voice_callattempt) do
      add :visit_id, :bigint
      add :phase, :string, size: 20
      add :scheduled_offset_minutes, :integer
      add :external_call_id, :string, size: 100
      add :status, :string, size: 20, null: false, default: "SCHEDULED"
      add :recording_url, :string
      add :transcript, :text
      add :summary, :text
      add :summary_title, :string
      add :analysis, :map, null: false, default: %{}
      add :scheduled_time, :utc_datetime
      add :executed_at, :utc_datetime
      add :retry_count, :integer, null: false, default: 0
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create_if_not_exists index(:voice_callattempt, [:external_call_id])
    create_if_not_exists index(:voice_callattempt, [:status])
  end
end
```

- [ ] **Step 3: Migrate and verify**

Run: `mix ecto.migrate`
Then: `psql -d florina_dev -c "\d voice_callattempt"`
Expected: table with the columns above.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations
git commit -m "dev: add voice_callattempt mirror table for local Phoenix dev/test"
```

---

## Task 2: `CallAttempt` Ecto schema

**Files:** Create `lib/florina/calls/call_attempt.ex` · Test `test/florina/calls/call_attempt_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Florina.Calls.CallAttemptTest do
  use Florina.DataCase, async: true
  alias Florina.Calls.CallAttempt
  alias Florina.Repo

  test "round-trips a row in voice_callattempt" do
    {:ok, ca} =
      %CallAttempt{}
      |> CallAttempt.webhook_changeset(%{
        external_call_id: "conv_123",
        status: "SCHEDULED",
        phase: "POST"
      })
      |> Repo.insert()

    assert Repo.get(CallAttempt, ca.id).external_call_id == "conv_123"
  end
end
```

- [ ] **Step 2: Run it — expect FAIL** (`Florina.Calls.CallAttempt` undefined)

Run: `mix test test/florina/calls/call_attempt_test.exs`

- [ ] **Step 3: Implement the schema**

```elixir
defmodule Florina.Calls.CallAttempt do
  @moduledoc "Maps Django's existing `voice_callattempt` table (shared schema)."
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_callattempt" do
    field :visit_id, :integer
    field :phase, :string
    field :external_call_id, :string
    field :status, :string
    field :recording_url, :string
    field :transcript, :string
    field :summary, :string
    field :summary_title, :string
    field :analysis, :map, default: %{}
    timestamps()
  end

  @doc "Fields the webhook edge is allowed to write."
  def webhook_changeset(call_attempt, attrs) do
    call_attempt
    |> cast(attrs, [:external_call_id, :status, :phase, :transcript, :summary, :summary_title, :analysis])
    |> validate_required([:status])
  end
end
```

- [ ] **Step 4: Run it — expect PASS.** Run: `mix test test/florina/calls/call_attempt_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/florina/calls/call_attempt.ex
git commit -m "feat: Ecto schema mapping voice_callattempt"
```

---

## Task 3: Lookup in the `Calls` context

**Files:** Create `lib/florina/calls.ex` · Test `test/florina/calls_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Florina.CallsTest do
  use Florina.DataCase, async: true
  alias Florina.{Calls, Repo}
  alias Florina.Calls.CallAttempt

  defp insert_call(attrs) do
    {:ok, ca} = %CallAttempt{} |> CallAttempt.webhook_changeset(attrs) |> Repo.insert()
    ca
  end

  test "get_by_external_id/1 finds a call, or returns nil" do
    insert_call(%{external_call_id: "conv_abc", status: "INITIATED"})
    assert %CallAttempt{external_call_id: "conv_abc"} = Calls.get_by_external_id("conv_abc")
    assert Calls.get_by_external_id("missing") == nil
  end
end
```

- [ ] **Step 2: Run — expect FAIL** (`Florina.Calls` undefined). Run: `mix test test/florina/calls_test.exs`

- [ ] **Step 3: Implement**

```elixir
defmodule Florina.Calls do
  @moduledoc "Context for the call real-time edge."
  alias Florina.Repo
  alias Florina.Calls.CallAttempt

  def get_by_external_id(nil), do: nil
  def get_by_external_id(external_id),
    do: Repo.get_by(CallAttempt, external_call_id: external_id)

  def get(id), do: Repo.get(CallAttempt, id)
end
```

- [ ] **Step 4: Run — expect PASS.** Run: `mix test test/florina/calls_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/florina/calls.ex
git commit -m "feat: Calls.get_by_external_id lookup"
```

---

## Task 4: ElevenLabs signature verification (security-critical)

**Files:** Create `lib/florina/integrations/eleven_labs_signature.ex` · Test `test/florina/integrations/eleven_labs_signature_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Florina.Integrations.ElevenLabsSignatureTest do
  use ExUnit.Case, async: true
  alias Florina.Integrations.ElevenLabsSignature, as: Sig

  @secret "wsec_test"
  @body ~s({"hello":"world"})

  defp header(ts, body, secret) do
    mac = :crypto.mac(:hmac, :sha256, secret, "#{ts}." <> body) |> Base.encode16(case: :lower)
    "t=#{ts},v0=#{mac}"
  end

  test "accepts a valid, fresh signature" do
    ts = 1_900_000_000
    assert :ok = Sig.verify(header(ts, @body, @secret), @body, @secret, ts)
  end

  test "rejects a tampered body" do
    ts = 1_900_000_000
    assert {:error, :mismatch} = Sig.verify(header(ts, @body, @secret), "OTHER", @secret, ts)
  end

  test "rejects an expired timestamp" do
    ts = 1_900_000_000
    assert {:error, :expired} = Sig.verify(header(ts, @body, @secret), @body, @secret, ts + 4000)
  end

  test "fails closed with no secret" do
    assert {:error, :no_secret} = Sig.verify(header(1, @body, @secret), @body, "", 1)
  end

  test "rejects a malformed header" do
    assert {:error, :malformed} = Sig.verify("garbage", @body, @secret, 1)
  end
end
```

- [ ] **Step 2: Run — expect FAIL.** Run: `mix test test/florina/integrations/eleven_labs_signature_test.exs`

- [ ] **Step 3: Implement**

```elixir
defmodule Florina.Integrations.ElevenLabsSignature do
  @moduledoc "Verifies ElevenLabs webhook signatures. Mirrors voice/webhook_security.py."
  @tolerance_seconds 30 * 60

  @spec verify(String.t() | nil, binary(), String.t() | nil, integer()) ::
          :ok | {:error, atom()}
  def verify(signature_header, raw_body, secret, now \\ System.system_time(:second))

  def verify(_h, _b, secret, _now) when secret in [nil, ""], do: {:error, :no_secret}

  def verify(signature_header, raw_body, secret, now) do
    with {:ok, ts, v0} <- parse(signature_header),
         :ok <- check_freshness(ts, now),
         expected <- compute(ts, raw_body, secret),
         true <- Plug.Crypto.secure_compare(expected, v0) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :mismatch}
    end
  end

  defp parse(header) when is_binary(header) do
    parts = for kv <- String.split(header, ","), into: %{} do
      case String.split(String.trim(kv), "=", parts: 2) do
        [k, v] -> {k, v}
        _ -> {"", ""}
      end
    end

    with t when is_binary(t) <- parts["t"],
         v0 when is_binary(v0) <- parts["v0"],
         {ts_int, ""} <- Integer.parse(t) do
      {:ok, ts_int, v0}
    else
      _ -> {:error, :malformed}
    end
  end

  defp parse(_), do: {:error, :malformed}

  defp check_freshness(ts, now) when abs(now - ts) <= @tolerance_seconds, do: :ok
  defp check_freshness(_ts, _now), do: {:error, :expired}

  defp compute(ts, raw_body, secret) do
    :crypto.mac(:hmac, :sha256, secret, "#{ts}." <> raw_body) |> Base.encode16(case: :lower)
  end
end
```

- [ ] **Step 4: Run — expect PASS (all 5).** Run: `mix test test/florina/integrations/eleven_labs_signature_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/florina/integrations/eleven_labs_signature.ex
git commit -m "feat: ElevenLabs webhook signature verification (fail-closed)"
```

---

## Task 5: Cache the raw request body (needed for signing)

**Files:** Create `lib/florina_web/raw_body_reader.ex` · Modify `lib/florina_web/endpoint.ex`

> No isolated test — verified by the controller test in Task 7 (a valid signature only passes if the raw body was preserved).

- [ ] **Step 1: Create the reader**

```elixir
defmodule FlorinaWeb.RawBodyReader do
  @moduledoc "Caches the raw request body so webhook signatures can be verified."
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    {:ok, body, update_in(conn.assigns[:raw_body], &[body | &1 || []])}
  end
end
```

- [ ] **Step 2: Wire it into `Plug.Parsers` in `endpoint.ex`**

Find the existing `plug Plug.Parsers,` block and set the JSON parser to use the reader:

```elixir
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    body_reader: {FlorinaWeb.RawBodyReader, :read_body, []},
    json_decoder: Phoenix.json_library()
```

- [ ] **Step 3: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add lib/florina_web/raw_body_reader.ex lib/florina_web/endpoint.ex
git commit -m "feat: cache raw request body for webhook signature verification"
```

---

## Task 6: Apply a webhook payload to a call (update + broadcast)

**Files:** Modify `lib/florina/calls.ex` · Test `test/florina/calls_apply_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Florina.CallsApplyTest do
  use Florina.DataCase, async: true
  alias Florina.{Calls, Repo}
  alias Florina.Calls.CallAttempt

  setup do
    {:ok, ca} =
      %CallAttempt{}
      |> CallAttempt.webhook_changeset(%{external_call_id: "conv_x", status: "IN_PROGRESS"})
      |> Repo.insert()
    %{ca: ca}
  end

  test "writes transcript + summary and maps status to COMPLETED, then broadcasts", %{ca: ca} do
    Phoenix.PubSub.subscribe(Florina.PubSub, "calls")

    payload = %{
      "type" => "post_call_transcription",
      "data" => %{
        "conversation_id" => "conv_x",
        "status" => "done",
        "transcript" => [%{"role" => "agent", "message" => "Buna ziua"}, %{"role" => "user", "message" => "Salut"}],
        "analysis" => %{"transcript_summary" => "Scurt rezumat"}
      }
    }

    assert {:ok, updated} = Calls.apply_elevenlabs_webhook(payload)
    assert updated.status == "COMPLETED"
    assert updated.summary == "Scurt rezumat"
    assert updated.transcript =~ "Buna ziua"
    assert Repo.get(CallAttempt, ca.id).status == "COMPLETED"
    assert_receive {:call_updated, %CallAttempt{id: id}} when id == ca.id
  end

  test "returns :not_found for an unknown conversation" do
    assert {:error, :not_found} =
             Calls.apply_elevenlabs_webhook(%{"data" => %{"conversation_id" => "nope"}})
  end
end
```

- [ ] **Step 2: Run — expect FAIL.** Run: `mix test test/florina/calls_apply_test.exs`

- [ ] **Step 3: Implement in `lib/florina/calls.ex`** (add to the module)

```elixir
  import Ecto.Changeset

  @doc "Apply an ElevenLabs post-call webhook payload to the matching call row."
  def apply_elevenlabs_webhook(%{} = payload) do
    data = Map.get(payload, "data", payload)
    conversation_id = data["conversation_id"]
    call_attempt_id = get_in(data, ["metadata", "call_attempt_id"])

    case find_call(conversation_id, call_attempt_id) do
      nil ->
        {:error, :not_found}

      %CallAttempt{} = ca ->
        transcript = extract_transcript(data["transcript"])
        summary = get_in(data, ["analysis", "transcript_summary"]) || get_in(data, ["analysis", "summary"])

        attrs =
          %{status: map_status(data["status"], transcript)}
          |> maybe_put(:transcript, transcript)
          |> maybe_put(:summary, summary)

        with {:ok, updated} <- ca |> CallAttempt.webhook_changeset(attrs) |> Repo.update() do
          Phoenix.PubSub.broadcast(Florina.PubSub, "calls", {:call_updated, updated})
          {:ok, updated}
        end
    end
  end

  defp find_call(conversation_id, nil), do: get_by_external_id(conversation_id)
  defp find_call(conversation_id, call_attempt_id) do
    get_by_external_id(conversation_id) || get(call_attempt_id)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # ElevenLabs status -> our CallStatus. "done"/transcript present => COMPLETED.
  defp map_status(status, transcript) do
    case to_string(status) |> String.upcase() do
      "IN_PROGRESS" -> "IN_PROGRESS"
      "RINGING" -> "IN_PROGRESS"
      "FAILED" -> "FAILED"
      "NO_ANSWER" -> "NO_ANSWER"
      _ -> if transcript not in [nil, ""] or String.downcase(to_string(status)) == "done", do: "COMPLETED", else: "FAILED"
    end
  end

  defp extract_transcript(list) when is_list(list) do
    list
    |> Enum.map(fn turn -> turn["message"] || turn["text"] || "" end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> nil_if_blank()
  end

  defp extract_transcript(text) when is_binary(text), do: nil_if_blank(text)
  defp extract_transcript(%{"text" => text}) when is_binary(text), do: nil_if_blank(text)
  defp extract_transcript(_), do: nil

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s
```

- [ ] **Step 4: Run — expect PASS.** Run: `mix test test/florina/calls_apply_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/florina/calls.ex
git commit -m "feat: apply ElevenLabs webhook to call row + broadcast"
```

---

## Task 7: Webhook endpoint + route

**Files:** Create `lib/florina_web/controllers/webhook/eleven_labs_controller.ex` · Modify `lib/florina_web/router.ex` · Test `test/florina_web/controllers/webhook/eleven_labs_controller_test.exs`

- [ ] **Step 1: Add config** in `config/runtime.exs` (inside the `if config_env() == :prod` is NOT right — webhooks run in all envs; add near the top, unconditionally):

```elixir
config :florina, :elevenlabs_webhook_secret, System.get_env("ELEVENLABS_WEBHOOK_SECRET")
```

For tests, set it in `config/test.exs`:

```elixir
config :florina, :elevenlabs_webhook_secret, "wsec_test"
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule FlorinaWeb.Webhook.ElevenLabsControllerTest do
  use FlorinaWeb.ConnCase, async: true
  alias Florina.{Calls, Repo}
  alias Florina.Calls.CallAttempt

  @secret "wsec_test"

  defp sign(body, ts) do
    mac = :crypto.mac(:hmac, :sha256, @secret, "#{ts}." <> body) |> Base.encode16(case: :lower)
    "t=#{ts},v0=#{mac}"
  end

  defp post_webhook(conn, body, sig) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("elevenlabs-signature", sig)
    |> post(~p"/webhooks/elevenlabs", body)
  end

  setup do
    {:ok, ca} =
      %CallAttempt{} |> CallAttempt.webhook_changeset(%{external_call_id: "conv_y", status: "IN_PROGRESS"}) |> Repo.insert()
    %{ca: ca}
  end

  test "valid signature updates the call and returns 200", %{conn: conn, ca: ca} do
    body = Jason.encode!(%{"data" => %{"conversation_id" => "conv_y", "status" => "done", "transcript" => "Salut"}})
    ts = System.system_time(:second)
    conn = post_webhook(conn, body, sign(body, ts))
    assert json_response(conn, 200)["status"] == "ok"
    assert Repo.get(CallAttempt, ca.id).status == "COMPLETED"
  end

  test "invalid signature is rejected with 401", %{conn: conn} do
    body = Jason.encode!(%{"data" => %{"conversation_id" => "conv_y"}})
    conn = post_webhook(conn, body, "t=#{System.system_time(:second)},v0=deadbeef")
    assert conn.status == 401
  end

  test "unknown call returns 200 (no provider retries)", %{conn: conn} do
    body = Jason.encode!(%{"data" => %{"conversation_id" => "missing", "status" => "done"}})
    ts = System.system_time(:second)
    conn = post_webhook(conn, body, sign(body, ts))
    assert conn.status == 200
  end
end
```

- [ ] **Step 3: Run — expect FAIL.** Run: `mix test test/florina_web/controllers/webhook/eleven_labs_controller_test.exs`

- [ ] **Step 4: Add the route** in `router.ex` (new pipeline + scope, outside `:browser`):

```elixir
  pipeline :webhook do
    plug :accepts, ["json"]
  end

  scope "/webhooks", FlorinaWeb.Webhook do
    pipe_through :webhook
    post "/elevenlabs", ElevenLabsController, :create
  end
```

- [ ] **Step 5: Implement the controller**

```elixir
defmodule FlorinaWeb.Webhook.ElevenLabsController do
  use FlorinaWeb, :controller
  require Logger
  alias Florina.Calls
  alias Florina.Integrations.ElevenLabsSignature

  def create(conn, params) do
    secret = Application.get_env(:florina, :elevenlabs_webhook_secret)
    raw_body = conn.assigns |> Map.get(:raw_body, []) |> Enum.reverse() |> IO.iodata_to_binary()
    signature = get_req_header(conn, "elevenlabs-signature") |> List.first()

    case ElevenLabsSignature.verify(signature, raw_body, secret) do
      :ok ->
        handle(conn, params)

      {:error, :no_secret} ->
        Logger.error("ElevenLabs webhook secret not configured")
        conn |> put_status(503) |> json(%{error: "not configured"})

      {:error, reason} ->
        Logger.warning("ElevenLabs webhook rejected: #{reason}")
        conn |> put_status(401) |> json(%{error: "invalid signature"})
    end
  end

  defp handle(conn, params) do
    case Calls.apply_elevenlabs_webhook(params) do
      {:ok, _ca} -> json(conn, %{status: "ok"})
      # 200 on not-found so the provider does not keep retrying a call we don't track
      {:error, :not_found} -> conn |> put_status(200) |> json(%{status: "ignored"})
    end
  end
end
```

- [ ] **Step 6: Run — expect PASS (all 3).** Run: `mix test test/florina_web/controllers/webhook/eleven_labs_controller_test.exs`

- [ ] **Step 7: Full suite + strict compile**

Run: `mix test` then `mix compile --warnings-as-errors` then `mix format`
Expected: all green, no warnings, no format diffs.

- [ ] **Step 8: Commit**

```bash
git add lib/florina_web/controllers/webhook/eleven_labs_controller.ex lib/florina_web/router.ex config/runtime.exs config/test.exs
git commit -m "feat: ElevenLabs webhook endpoint (verify, update call, broadcast)"
```

---

## Self-Review

- **Spec coverage:** webhook receiver (Tasks 5–7), signature fail-closed (Task 4 + 7), update transcript/summary/status (Task 6), broadcast for dashboard (Task 6), shared-schema DB access (Tasks 1–3). Slice-spec items deferred by design: Twilio webhook, dashboard UI, tenant routing → follow-up plans below.
- **Placeholders:** none — every step has concrete code/commands.
- **Type consistency:** `webhook_changeset/2`, `get_by_external_id/1`, `apply_elevenlabs_webhook/1`, `ElevenLabsSignature.verify/4` are defined once and used consistently; table `voice_callattempt` and status strings match the Django source.

## Follow-up plans (not in this plan)

1. **Twilio webhook** — call lifecycle events (SHA1 validation), same broadcast.
2. **Live calls dashboard** — LiveView subscribing to the `"calls"` PubSub topic.
3. **Per-tenant DB routing** — Ecto dynamic repos + subdomain tenant resolution (consumes Track 1); the highest-priority test is cross-tenant isolation.
