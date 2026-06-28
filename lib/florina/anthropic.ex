defmodule Florina.Anthropic do
  @moduledoc """
  Anthropic Messages API client — streaming and non-streaming.

  Two public functions:
  - `stream_chat/2` — SSE streaming for interactive use (Live Agent chat).
  - `complete/2`    — Single blocking completion for the prompt assembler.

  Both are defined as `@callback`s so tests can swap in `Florina.Anthropic.Stub`
  without making real API calls. The active implementation is chosen via
  `Application.get_env(:florina, :anthropic_client, Florina.Anthropic)`.
  """

  @callback stream_chat([map()], keyword()) :: :ok | {:error, term()}

  @doc """
  Single (non-streaming) chat completion.

  Returns `{:ok, %{text: string, input_tokens: non_neg_integer, output_tokens: non_neg_integer}}`
  or `{:error, term()}`.

  Options: `:model`, `:max_tokens`, `:system`.
  """
  @callback complete([map()], keyword()) ::
              {:ok,
               %{text: String.t(), input_tokens: non_neg_integer, output_tokens: non_neg_integer}}
              | {:error, term()}

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
    api_key = Application.get_env(:florina, :anthropic_api_key)

    if api_key in [nil, ""] do
      {:error, :api_key_not_configured}
    else
      model =
        Keyword.get(
          opts,
          :model,
          Application.get_env(:florina, :anthropic_model, "claude-sonnet-4-6")
        )

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
          receive_timeout: 120_000,
          connect_options: [timeout: 15_000],
          into: fn {:data, data}, {req, resp} ->
            buffer = (resp.private[:sse_buf] || "") <> data
            {deltas, rest} = SSE.parse(buffer)
            Enum.each(deltas, on_delta)
            {:cont, {req, put_in(resp.private[:sse_buf], rest)}}
          end
        )

      case result do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http, status, resp_body |> inspect() |> String.slice(0, 300)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Non-streaming single completion. Used by the prompt assembler.

  Returns `{:ok, %{text: string, input_tokens: int, output_tokens: int}}`
  or `{:error, term()}`. Never raises.
  """
  @impl true
  def complete(messages, opts \\ []) do
    api_key = Application.get_env(:florina, :anthropic_api_key)

    if api_key in [nil, ""] do
      {:error, :api_key_not_configured}
    else
      model =
        Keyword.get(
          opts,
          :model,
          Application.get_env(:florina, :anthropic_model, "claude-sonnet-4-6")
        )

      body =
        %{
          model: model,
          max_tokens: Keyword.get(opts, :max_tokens, 4096),
          messages: messages
        }
        |> maybe_put(:system, Keyword.get(opts, :system))

      case Req.post(@endpoint,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", @version},
               {"content-type", "application/json"}
             ],
             json: body,
             receive_timeout: 120_000,
             connect_options: [timeout: 15_000]
           ) do
        {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _], "usage" => usage}}} ->
          {:ok,
           %{
             text: text,
             input_tokens: Map.get(usage, "input_tokens", 0),
             output_tokens: Map.get(usage, "output_tokens", 0)
           }}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:http, status, resp_body |> inspect() |> String.slice(0, 300)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
