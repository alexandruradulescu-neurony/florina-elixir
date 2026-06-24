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
          {:ok,
           %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => t}}} ->
            [t]

          _ ->
            []
        end

      _ ->
        []
    end)
  end
end
