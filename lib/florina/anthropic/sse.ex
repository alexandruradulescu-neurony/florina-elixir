defmodule Florina.Anthropic.SSE do
  @moduledoc """
  Pure parser: a byte buffer of Anthropic SSE -> `{events, remaining_buffer}`.

  Each event is a tagged tuple the streaming client acts on:
  - `{:delta, text}`   — a text chunk to append
  - `{:error, reason}` — a mid-stream `error` event (Anthropic sends these under
    overload after the 200 header) or a `max_tokens` truncation, so the caller
    can fail instead of presenting a partial reply as complete.
  """

  @doc "Split on the SSE event delimiter; parse complete events, keep the trailing partial."
  def parse(buffer) when is_binary(buffer) do
    parts = String.split(buffer, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.flat_map(complete, &events/1), rest}
  end

  defp events(event_block) do
    event_block
    |> String.split("\n")
    |> Enum.flat_map(fn
      "data:" <> json ->
        case Jason.decode(String.trim(json)) do
          {:ok,
           %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => t}}} ->
            [{:delta, t}]

          {:ok, %{"type" => "error", "error" => err}} when is_map(err) ->
            [{:error, err["message"] || err["type"] || "stream error"}]

          {:ok, %{"type" => "message_delta", "delta" => %{"stop_reason" => "max_tokens"}}} ->
            [{:error, "response truncated (max_tokens)"}]

          _ ->
            []
        end

      _ ->
        []
    end)
  end
end
