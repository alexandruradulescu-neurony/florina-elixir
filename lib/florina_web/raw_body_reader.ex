defmodule FlorinaWeb.RawBodyReader do
  @moduledoc """
  Caches the raw request body so webhook signatures can be verified.

  Plug.Parsers calls this on EVERY request, but we only retain the body for the
  webhook/voice paths that need it for signature verification — never for other
  routes (e.g. the admin login POST), so a plaintext credential body can't linger
  in `conn.assigns` for a later error-tracker to serialize.

  It returns `{:more, partial, conn}` for a body larger than the read chunk size
  and `{:ok, body, conn}` for the final chunk. We accumulate every chunk
  (prepended; the consumer reverses + joins) so large payloads still verify, and
  pass `{:error, _}` through instead of crashing with a MatchError → 500.
  """
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, maybe_cache(conn, body)}
      {:more, body, conn} -> {:more, body, maybe_cache(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Retain the body only on signature-verified webhook routes:
  #   /t/:slug/webhooks/...  and  /t/:slug/voice/...
  defp maybe_cache(%{path_info: ["t", _slug, "webhooks" | _]} = conn, chunk),
    do: cache_chunk(conn, chunk)

  defp maybe_cache(%{path_info: ["t", _slug, "voice" | _]} = conn, chunk),
    do: cache_chunk(conn, chunk)

  defp maybe_cache(conn, _chunk), do: conn

  defp cache_chunk(conn, chunk) do
    update_in(conn.assigns[:raw_body], &[chunk | &1 || []])
  end
end
