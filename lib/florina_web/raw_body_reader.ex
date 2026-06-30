defmodule FlorinaWeb.RawBodyReader do
  @moduledoc """
  Caches the raw request body so webhook signatures can be verified.

  Plug.Parsers calls this repeatedly: it returns `{:more, partial, conn}` for a
  body larger than the read chunk size and `{:ok, body, conn}` for the final
  chunk. We accumulate every chunk (prepended; the consumer reverses + joins) so
  large payloads still verify, and pass `{:error, _}` through instead of crashing
  with a MatchError → 500.
  """
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, cache_chunk(conn, body)}
      {:more, body, conn} -> {:more, body, cache_chunk(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cache_chunk(conn, chunk) do
    update_in(conn.assigns[:raw_body], &[chunk | &1 || []])
  end
end
