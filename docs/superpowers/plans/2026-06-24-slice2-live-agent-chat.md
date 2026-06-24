# Slice 2 — Live Agent Chat — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A `/chat` LiveView (behind the dashboard password) where a manager's question streams a Claude (`claude-sonnet-4-6`) response token-by-token, via raw HTTP (`Req`) against the Anthropic Messages API with SSE.

**Architecture:** A pure SSE parser (unit-tested), a thin streaming client `Florina.Anthropic` behind a behaviour (so tests swap in a stub — no real API calls, no token spend), and `FlorinaWeb.ChatLive` which runs the stream in a `Task` that sends each delta back to the LiveView process.

**Tech Stack:** Phoenix LiveView, `Req` (already a dep), `Jason`, Anthropic Messages API (`/v1/messages`, `stream: true`).

**Branch:** build on `develop`. Default model `claude-sonnet-4-6` (NOT Opus — cost). API key server-side only.

---

## File Structure

- Create `lib/florina/anthropic.ex` — behaviour + real streaming client.
- Create `lib/florina/anthropic/sse.ex` — pure SSE→text-delta parser.
- Create `lib/florina_web/live/chat_live.ex` — the chat LiveView.
- Modify `lib/florina_web/router.ex` — `live "/chat"` behind `:dashboard_auth`.
- Modify `config/config.exs`, `config/test.exs`, `config/runtime.exs` — model, API key, client module.
- Tests (local, git-ignored): `test/florina/anthropic/sse_test.exs`, `test/florina_web/live/chat_live_test.exs`.

---

## Task 1: SSE parser (pure, fully testable)

**Files:** Create `lib/florina/anthropic/sse.ex` · Test `test/florina/anthropic/sse_test.exs`

- [ ] **Step 1: Failing test**

```elixir
defmodule Florina.Anthropic.SSETest do
  use ExUnit.Case, async: true
  alias Florina.Anthropic.SSE

  test "extracts text deltas from complete events and keeps the trailing partial" do
    chunk = """
    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" world"}}

    event: content_block_delta
    data: {"type":"content_block_delta","delta":{"type":"text_del\
    """

    {deltas, rest} = SSE.parse(chunk)
    assert deltas == ["Hello", " world"]
    assert rest =~ "text_del"  # incomplete event retained for the next chunk
  end

  test "ignores non-text events" do
    chunk = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
    assert {[], ""} = SSE.parse(chunk)
  end
end
```

- [ ] **Step 2: Run — expect FAIL.** Run: `mix test test/florina/anthropic/sse_test.exs`

- [ ] **Step 3: Implement**

```elixir
defmodule Florina.Anthropic.SSE do
  @moduledoc "Pure parser: a byte buffer of Anthropic SSE -> {text_deltas, remaining_buffer}."

  @doc "Split on the SSE event delimiter; parse complete events, keep the trailing partial."
  def parse(buffer) when is_binary(buffer) do
    parts = String.split(buffer, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.flat_map(complete, &text_deltas/1), rest}
  end

  defp text_deltas(event_block) do
    event_block
    |> String.split("\n")
    |> Enum.flat_map(fn
      "data:" <> json ->
        case Jason.decode(String.trim(json)) do
          {:ok, %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => t}}} -> [t]
          _ -> []
        end

      _ ->
        []
    end)
  end
end
```

- [ ] **Step 4: Run — expect PASS.** Run: `mix test test/florina/anthropic/sse_test.exs`
- [ ] **Step 5: Commit** — `git add lib/florina/anthropic/sse.ex` then commit `feat: Anthropic SSE delta parser`

---

## Task 2: `Florina.Anthropic` behaviour + streaming client

**Files:** Create `lib/florina/anthropic.ex`

> No isolated unit test (it does real HTTP). The SSE logic is covered in Task 1; ChatLive uses a stub (Task 4). Keep this module thin.

- [ ] **Step 1: Implement**

```elixir
defmodule Florina.Anthropic do
  @moduledoc """
  Streams a chat completion from the Anthropic Messages API over raw HTTP (Req + SSE).
  Elixir has no official Anthropic SDK, so this is the documented raw-HTTP approach.
  """
  @callback stream_chat([map()], keyword()) :: :ok | {:error, term()}

  alias Florina.Anthropic.SSE

  @endpoint "https://api.anthropic.com/v1/messages"
  @version "2023-06-01"

  @doc """
  `messages` is a list of %{role: "user"|"assistant", content: "..."}.
  Options: `:on_delta` (fn text -> ... end), `:model`, `:max_tokens`, `:system`.
  """
  @behaviour Florina.Anthropic
  @impl true
  def stream_chat(messages, opts \\ []) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    api_key = Application.fetch_env!(:florina, :anthropic_api_key)
    model = Keyword.get(opts, :model, Application.get_env(:florina, :anthropic_model, "claude-sonnet-4-6"))

    body =
      %{
        model: model,
        max_tokens: Keyword.get(opts, :max_tokens, 2048),
        stream: true,
        messages: messages
      }
      |> maybe_put(:system, Keyword.get(opts, :system))

    result =
      Req.post(@endpoint,
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", @version},
          {"content-type", "application/json"}
        ],
        json: body,
        into: fn {:data, data}, {req, resp} ->
          buffer = (resp.private[:sse_buf] || "") <> data
          {deltas, rest} = SSE.parse(buffer)
          Enum.each(deltas, on_delta)
          {:cont, {req, put_in(resp.private[:sse_buf], rest)}}
        end
      )

    case result do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
```

- [ ] **Step 2: Compile** — `mix compile --warnings-as-errors`
- [ ] **Step 3: Commit** — `git add lib/florina/anthropic.ex` then commit `feat: Anthropic streaming chat client (Sonnet 4.6 default)`

---

## Task 3: Config (key, model, swappable client)

**Files:** Modify `config/config.exs`, `config/test.exs`, `config/runtime.exs`

- [ ] **Step 1:** `config/config.exs` — defaults:
```elixir
config :florina,
  anthropic_model: "claude-sonnet-4-6",
  anthropic_client: Florina.Anthropic
```

- [ ] **Step 2:** `config/runtime.exs` (prod block) — read the key from env:
```elixir
  config :florina, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY")
```
Also add a dev default in `config/dev.exs` if you want local manual testing: `config :florina, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY")`.

- [ ] **Step 3:** `config/test.exs` — stub client + dummy key (no real calls):
```elixir
config :florina, :anthropic_client, Florina.Anthropic.Stub
config :florina, :anthropic_api_key, "test-key"
```

- [ ] **Step 4: Commit** — `git add config/config.exs config/test.exs config/runtime.exs config/dev.exs` then commit `feat: Anthropic config (model, key, swappable client)`

---

## Task 4: `ChatLive` + route + stub + tests

**Files:** Create `lib/florina_web/live/chat_live.ex`, `test/support/anthropic_stub.ex` (git-ignored with the rest of `test/`) · Modify `lib/florina_web/router.ex` · Test `test/florina_web/live/chat_live_test.exs`

- [ ] **Step 1: Stub client** (test support — local only) `test/support/anthropic_stub.ex`:
```elixir
defmodule Florina.Anthropic.Stub do
  @behaviour Florina.Anthropic
  @impl true
  def stream_chat(_messages, opts) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    Enum.each(["Hi", " there", "!"], on_delta)
    :ok
  end
end
```

- [ ] **Step 2: Failing test**

```elixir
defmodule FlorinaWeb.ChatLiveTest do
  use FlorinaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  defp auth(conn),
    do: put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth("admin", "test-pass"))

  test "rejects without basic auth", %{conn: conn} do
    assert get(conn, ~p"/chat").status == 401
  end

  test "streams an assistant reply on submit", %{conn: conn} do
    {:ok, view, _html} = live(auth(conn), ~p"/chat")
    html = view |> form("#chat-form", message: "Hello") |> render_submit()
    # the stub streams "Hi there!" — assert it appears
    assert render(view) =~ "Hi there!"
    assert html =~ "Hello"  # the user's message is shown too
  end
end
```

- [ ] **Step 3: Run — expect FAIL.** Run: `mix test test/florina_web/live/chat_live_test.exs`

- [ ] **Step 4: Implement the LiveView**

```elixir
defmodule FlorinaWeb.ChatLive do
  use FlorinaWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, messages: [], streaming: nil, input: "")}
  end

  @impl true
  def handle_event("send", %{"message" => text}, socket) when text != "" do
    history = socket.assigns.messages ++ [%{role: "user", content: text}]
    lv = self()
    client = Application.get_env(:florina, :anthropic_client, Florina.Anthropic)

    Task.start(fn ->
      client.stream_chat(Enum.map(history, &Map.take(&1, [:role, :content])),
        on_delta: fn delta -> send(lv, {:delta, delta}) end
      )
      |> case do
        :ok -> send(lv, :done)
        {:error, reason} -> send(lv, {:error, reason})
      end
    end)

    {:noreply, assign(socket, messages: history, streaming: "", input: "")}
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:delta, text}, socket),
    do: {:noreply, assign(socket, streaming: (socket.assigns.streaming || "") <> text)}

  def handle_info(:done, socket) do
    msg = %{role: "assistant", content: socket.assigns.streaming || ""}
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [msg], streaming: nil)}
  end

  def handle_info({:error, _reason}, socket) do
    msg = %{role: "assistant", content: "(sorry — something went wrong)"}
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [msg], streaming: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold mb-4">Assistant</h1>
    <div id="messages" class="space-y-3 mb-4">
      <div :for={m <- @messages} class={["p-3 rounded", m.role == "user" && "bg-base-200"]}>
        <span class="font-medium">{m.role}:</span> {m.content}
      </div>
      <div :if={@streaming != nil} class="p-3 rounded">
        <span class="font-medium">assistant:</span> {@streaming}
      </div>
    </div>
    <form id="chat-form" phx-submit="send">
      <input type="text" name="message" value={@input} autocomplete="off" placeholder="Ask the assistant..." class="input input-bordered w-full" />
    </form>
    """
  end
end
```

(Use the project's HEEx syntax; if `{...}` body interpolation isn't accepted, use `<%= %>`. The test asserts on rendered text.)

- [ ] **Step 5: Add the route** in `router.ex` (in the `:dashboard_auth` scope alongside `/calls`):
```elixir
    live "/chat", ChatLive
```

- [ ] **Step 6: Run — expect PASS (both cases).** Run: `mix test test/florina_web/live/chat_live_test.exs`
- [ ] **Step 7: Full suite + strict compile + format** — `mix test`, `mix compile --warnings-as-errors`, `mix format`
- [ ] **Step 8: Commit** — `git add lib/florina_web/live/chat_live.ex lib/florina_web/router.ex` then commit `feat: live agent chat (streaming LiveView, Sonnet 4.6)`

---

## Self-Review

- **Spec coverage:** streaming chat (Tasks 1,2,4), Sonnet 4.6 default + server-side key (Task 2,3), behind dashboard auth (Task 4), conversation history in the LiveView (Task 4). v1 plain (no data grounding) — per the spec.
- **Placeholders:** none.
- **Type consistency:** `stream_chat/2` behaviour, `:on_delta`, `{:delta,_}`/`:done`/`{:error,_}` messages, `:anthropic_client` config key are consistent across tasks.

## Deploy note

Add `ANTHROPIC_API_KEY` to Railway env when this ships to live (same as `DASHBOARD_PASS`). Update DEPLOY.md then.
