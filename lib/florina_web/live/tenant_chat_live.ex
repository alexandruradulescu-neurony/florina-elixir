defmodule FlorinaWeb.TenantChatLive do
  @moduledoc """
  Per-tenant chat grounded in that tenant's own clients, visits, and recent
  calls. The grounding context (system prompt) is assembled in the LiveView
  process — which has TenantRepo pinned via TenantHook — BEFORE spawning the
  streaming Task, so the Task only calls Claude and never touches the DB.
  """
  use FlorinaWeb, :live_view
  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.Services.DataContext

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, messages: [], streaming: nil, input: "")}
  end

  @impl true
  # Ignore a new send while a reply is still streaming: a second concurrent Task
  # would interleave its deltas into the same buffer and commit a garbled message.
  def handle_event("send", _params, socket) when socket.assigns.streaming != nil do
    {:noreply, socket}
  end

  def handle_event("send", %{"message" => text}, socket) when text != "" do
    history = socket.assigns.messages ++ [%{role: "user", content: text}]
    lv = self()
    client = Application.get_env(:florina, :anthropic_client, Florina.Anthropic)

    # Build the grounding context HERE, in the LiveView process (TenantRepo is
    # pinned). The Task below must NOT do DB reads — it only calls Claude.
    system_prompt = DataContext.build_chat_context()

    Task.start(fn ->
      try do
        case client.stream_chat(
               Enum.map(history, &Map.take(&1, [:role, :content])),
               on_delta: fn delta -> send(lv, {:delta, delta}) end,
               system: system_prompt
             ) do
          :ok -> send(lv, :done)
          {:error, reason} -> send(lv, {:error, reason})
        end
      rescue
        e -> send(lv, {:error, e})
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
    <Layouts.agent_app flash={@flash} tenant={@tenant} current_agent={@current_agent} active={:chat}>
      <div class="mb-6">
        <h1 class="text-3xl font-extrabold tracking-[-0.01em] text-gray-900 dark:text-white">
          Assistant — {@tenant.name}
        </h1>
        <p class="text-sm text-gray-500 dark:text-gray-400">
          Grounded in {@tenant.name}'s clients, visits and calls.
        </p>
      </div>
      <div id="messages" class="space-y-3 mb-4">
        <div
          :for={m <- @messages}
          class={[
            "rounded-lg p-3 text-gray-700 dark:text-gray-300",
            m.role == "user" && "bg-gray-100 dark:bg-white/10"
          ]}
        >
          <span class="font-medium text-gray-900 dark:text-white">{m.role}:</span> {m.content}
        </div>
        <div :if={@streaming != nil} class="rounded-lg p-3 text-gray-700 dark:text-gray-300">
          <span class="font-medium text-gray-900 dark:text-white">assistant:</span> {@streaming}
        </div>
      </div>
      <form id="chat-form" phx-submit="send">
        <input
          type="text"
          name="message"
          value={@input}
          autocomplete="off"
          placeholder={"Ask about #{@tenant.name}'s clients, visits or calls…"}
          class="w-full rounded-md bg-white px-3 py-1.5 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 placeholder:text-gray-400 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500"
        />
        <div class="mt-2">
          <.button type="submit" variant="primary" disabled={@streaming != nil}>
            {if @streaming != nil, do: "Sending…", else: "Send"}
          </.button>
        </div>
      </form>
    </Layouts.agent_app>
    """
  end
end
