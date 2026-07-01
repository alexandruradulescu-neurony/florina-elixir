defmodule FlorinaWeb.Webhook.VoiceToolController do
  @moduledoc """
  Mid-call server tools the inbound concierge calls (ElevenLabs server tools).

  Authenticated with a shared secret header (`x-florina-voice-secret`) that the
  maintainer configures on each tool in ElevenLabs — server tools send static
  headers rather than the HMAC the webhooks use. Tenant is resolved from the URL
  slug. Each tool is scoped to the caller's `agent_id` (bound to the
  `{{agent_id}}` dynamic variable), so it can only reach that agent's meetings.
  """
  use FlorinaWeb, :controller
  require Logger

  alias Florina.Voice.Tools

  def find_meeting(conn, params) do
    with_auth(conn, fn ->
      candidates = Tools.find_meeting(params["agent_id"], params["query"] || "", params["phase"])
      json(conn, %{"candidates" => candidates})
    end)
  end

  def get_call_script(conn, params) do
    with_auth(conn, fn ->
      params["agent_id"]
      |> Tools.get_call_script(params["visit_id"], params["phase"])
      |> respond(conn)
    end)
  end

  def save_outcome(conn, params) do
    with_auth(conn, fn ->
      params["agent_id"]
      |> Tools.save_outcome(
        params["visit_id"],
        params["phase"],
        params["summary"],
        params["notes"]
      )
      |> respond(conn)
    end)
  end

  defp respond({:ok, result}, conn), do: json(conn, result)

  defp respond({:error, :not_found}, conn),
    do: conn |> put_status(404) |> json(%{error: "meeting not found"})

  defp respond({:error, _reason}, conn),
    do: conn |> put_status(400) |> json(%{error: "bad request"})

  defp with_auth(conn, fun) do
    secret = Application.get_env(:florina, :voice_tools_secret)
    provided = get_req_header(conn, "x-florina-voice-secret") |> List.first()

    cond do
      secret in [nil, ""] ->
        Logger.error("Voice tools secret not configured")
        conn |> put_status(503) |> json(%{error: "not configured"})

      is_binary(provided) and Plug.Crypto.secure_compare(secret, provided) ->
        fun.()

      true ->
        Logger.warning("Voice tool call rejected: bad secret")
        conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end
end
