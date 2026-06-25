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
      try do
        case client.stream_chat(Enum.map(history, &Map.take(&1, [:role, :content])),
               on_delta: fn delta -> send(lv, {:delta, delta}) end
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
    <Layouts.app flash={@flash}>
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
        <input
          type="text"
          name="message"
          value={@input}
          autocomplete="off"
          placeholder="Ask the assistant..."
          class="w-full rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content focus:outline-none focus:ring-2 focus:ring-primary/50"
        />
        <button
          type="submit"
          class="mt-2 inline-flex items-center justify-center gap-2 rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:opacity-90 disabled:opacity-50 cursor-pointer"
        >
          Send
        </button>
      </form>
    </Layouts.app>
    """
  end
end
