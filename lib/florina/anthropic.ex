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
          redirect: false,
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
            {events, rest} = SSE.parse(buffer)

            Enum.each(events, fn
              {:delta, text} -> on_delta.(text)
              _ -> :ok
            end)

            resp = put_in(resp.private[:sse_buf], rest)

            resp =
              case Enum.find_value(events, fn
                     {:error, reason} -> reason
                     _ -> nil
                   end) do
                nil -> resp
                reason -> put_in(resp.private[:sse_error], reason)
              end

            {:cont, {req, resp}}
          end
        )

      case result do
        # A 200 whose stream carried a mid-stream `error` event (Anthropic sends
        # these under overload AFTER the 200 header) must NOT be reported as a
        # clean completion — otherwise the partial reply is committed as final.
        {:ok, %{status: 200} = resp} ->
          case resp.private[:sse_error] do
            nil -> :ok
            reason -> {:error, {:stream_error, reason}}
          end

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
             redirect: false,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", @version},
               {"content-type", "application/json"}
             ],
             json: body,
             receive_timeout: 120_000,
             connect_options: [timeout: 15_000]
           ) do
        {:ok, %{status: 200, body: %{"content" => content, "usage" => usage} = body}}
        when is_list(content) ->
          {:ok,
           %{
             text: first_text(content),
             # `stop_reason: "max_tokens"` means the model hit the output cap and
             # the text is truncated — callers (e.g. document extraction) need to
             # know so they don't store a half-response as complete.
             stop_reason: body["stop_reason"],
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

  # First text block in a Messages `content` array. Robust to a leading non-text
  # block or an empty array (returns ""), rather than assuming content[0] is text.
  defp first_text(content) do
    Enum.find_value(content, "", fn
      %{"text" => t} when is_binary(t) -> t
      _ -> nil
    end)
  end
end
