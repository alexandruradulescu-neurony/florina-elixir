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
      <input
        type="text"
        name="message"
        value={@input}
        autocomplete="off"
        placeholder="Ask the assistant..."
        class="input input-bordered w-full"
      />
    </form>
    """
  end
end
