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
