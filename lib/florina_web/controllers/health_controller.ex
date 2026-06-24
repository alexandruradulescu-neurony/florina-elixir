defmodule FlorinaWeb.HealthController do
  use FlorinaWeb, :controller

  @doc """
  Liveness probe for deploy checks and uptime monitors.

  Deliberately minimal: returns a plain-text "ok" with no database access and no
  authentication, matching the behaviour of the old Django `/healthz/`.
  """
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
