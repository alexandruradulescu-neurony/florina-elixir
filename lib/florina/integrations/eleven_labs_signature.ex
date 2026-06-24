defmodule Florina.Integrations.ElevenLabsSignature do
  @moduledoc "Verifies ElevenLabs webhook signatures. Mirrors voice/webhook_security.py."
  @tolerance_seconds 30 * 60

  @spec verify(String.t() | nil, binary(), String.t() | nil, integer()) ::
          :ok | {:error, atom()}
  def verify(signature_header, raw_body, secret, now \\ System.system_time(:second))

  def verify(_h, _b, secret, _now) when secret in [nil, ""], do: {:error, :no_secret}

  def verify(_h, nil, _secret, _now), do: {:error, :malformed}

  def verify(signature_header, raw_body, secret, now) do
    with {:ok, ts, v0} <- parse(signature_header),
         :ok <- check_freshness(ts, now),
         expected <- compute(ts, raw_body, secret),
         true <- Plug.Crypto.secure_compare(expected, v0) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :mismatch}
    end
  end

  defp parse(header) when is_binary(header) do
    parts = for kv <- String.split(header, ","), into: %{} do
      case String.split(String.trim(kv), "=", parts: 2) do
        [k, v] -> {k, v}
        _ -> {"", ""}
      end
    end

    with t when is_binary(t) <- parts["t"],
         v0 when is_binary(v0) <- parts["v0"],
         {ts_int, ""} <- Integer.parse(t) do
      {:ok, ts_int, v0}
    else
      _ -> {:error, :malformed}
    end
  end

  defp parse(_), do: {:error, :malformed}

  defp check_freshness(ts, now) when abs(now - ts) <= @tolerance_seconds, do: :ok
  defp check_freshness(_ts, _now), do: {:error, :expired}

  defp compute(ts, raw_body, secret) do
    :crypto.mac(:hmac, :sha256, secret, "#{ts}." <> raw_body) |> Base.encode16(case: :lower)
  end
end
