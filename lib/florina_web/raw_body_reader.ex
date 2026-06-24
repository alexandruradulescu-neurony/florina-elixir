defmodule FlorinaWeb.RawBodyReader do
  @moduledoc "Caches the raw request body so webhook signatures can be verified."
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    {:ok, body, update_in(conn.assigns[:raw_body], &[body | &1 || []])}
  end
end
