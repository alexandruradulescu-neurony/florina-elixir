defmodule FlorinaWeb.Webhook.VoiceController do
  @moduledoc """
  Inbound voice-concierge webhooks from ElevenLabs.

  `personalize/2` is the pre-connect (Twilio personalization) webhook: it fires
  during the ring, is authenticated with the same HMAC signature scheme as the
  post-call webhook, and returns the caller-tailored greeting + context. Tenant is
  resolved from the URL slug (`/t/:slug/voice/...`), exactly like the post-call
  webhook.
  """
  use FlorinaWeb, :controller
  require Logger

  alias Florina.Integrations.ElevenLabsSignature
  alias Florina.Voice.Concierge

  def personalize(conn, params) do
    secret = Application.get_env(:florina, :elevenlabs_webhook_secret)
    raw_body = conn.assigns |> Map.get(:raw_body, []) |> Enum.reverse() |> IO.iodata_to_binary()
    signature = get_req_header(conn, "elevenlabs-signature") |> List.first()

    case ElevenLabsSignature.verify(signature, raw_body, secret) do
      :ok ->
        json(conn, Concierge.personalize(params, conn.assigns.tenant))

      {:error, :no_secret} ->
        Logger.error("Voice personalize webhook secret not configured")
        conn |> put_status(503) |> json(%{error: "not configured"})

      {:error, reason} ->
        Logger.warning("Voice personalize webhook rejected: #{reason}")
        conn |> put_status(401) |> json(%{error: "invalid signature"})
    end
  end
end
