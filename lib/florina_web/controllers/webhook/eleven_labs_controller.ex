defmodule FlorinaWeb.Webhook.ElevenLabsController do
  use FlorinaWeb, :controller
  require Logger
  alias Florina.Calls
  alias Florina.Integrations.ElevenLabsSignature

  def create(conn, params) do
    # Per-tenant secret (tenant pinned by :resolve_tenant); no global fallback.
    secret = Florina.Settings.get().elevenlabs_webhook_secret
    raw_body = conn.assigns |> Map.get(:raw_body, []) |> Enum.reverse() |> IO.iodata_to_binary()
    signature = get_req_header(conn, "elevenlabs-signature") |> List.first()

    case ElevenLabsSignature.verify(signature, raw_body, secret) do
      :ok ->
        handle(conn, params)

      {:error, :no_secret} ->
        Logger.error("ElevenLabs webhook secret not configured")
        conn |> put_status(503) |> json(%{error: "not configured"})

      {:error, reason} ->
        Logger.warning("ElevenLabs webhook rejected: #{reason}")
        conn |> put_status(401) |> json(%{error: "invalid signature"})
    end
  end

  defp handle(conn, params) do
    case Calls.apply_elevenlabs_webhook(params, conn.assigns.tenant.slug) do
      {:ok, _ca} ->
        json(conn, %{status: "ok"})

      # 200 on not-found so the provider does not keep retrying a call we don't track
      {:error, :not_found} ->
        conn |> put_status(200) |> json(%{status: "ignored"})

      {:error, reason} ->
        Logger.error("ElevenLabs webhook processing failed: #{describe_error(reason)}")
        conn |> put_status(500) |> json(%{error: "processing failed"})
    end
  end

  # Never log a full changeset here — its `changes` hold the transcript/summary.
  defp describe_error(%Ecto.Changeset{} = cs), do: inspect(cs.errors)
  defp describe_error(other), do: inspect(other)
end
