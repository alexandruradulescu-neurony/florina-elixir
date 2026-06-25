defmodule Florina.Integrations.Provider do
  @moduledoc """
  Dispatches to the configured provider implementation by `:google | :microsoft`,
  and holds shared OAuth helpers: callback URI, signed state, JWT-claim decoding,
  and token-freshness/refresh.
  """
  alias Florina.OAuth.Credential

  @registry %{
    google: {:oauth_provider_google, Florina.Integrations.Providers.Google},
    microsoft: {:oauth_provider_microsoft, Florina.Integrations.Providers.Microsoft}
  }

  @state_salt "agent_oauth_state"

  def impl(provider) when is_atom(provider) do
    {key, default} = Map.fetch!(@registry, provider)
    Application.get_env(:florina, key, default)
  end

  def impl(provider) when is_binary(provider), do: impl(String.to_existing_atom(provider))

  def for_credential(%Credential{provider: p}), do: impl(p)

  def supported?(p) when is_atom(p), do: Map.has_key?(@registry, p)

  def sign_state(endpoint_or_conn, tenant_slug, provider) do
    Phoenix.Token.sign(endpoint_or_conn, @state_salt, %{
      tenant_slug: tenant_slug,
      provider: to_string(provider)
    })
  end

  def verify_state(endpoint_or_conn, state, max_age \\ 600) do
    Phoenix.Token.verify(endpoint_or_conn, @state_salt, state, max_age: max_age)
  end

  @doc """
  The fixed OAuth callback URL — one per provider, NOT per tenant. The tenant is
  recovered from the signed `state` in the callback, so a single redirect URI
  (`/auth/:provider/callback`) is registered once with Google/Microsoft and works
  for every tenant.
  """
  def redirect_uri(provider) do
    base =
      System.get_env("OAUTH_REDIRECT_BASE") ||
        Application.get_env(:florina, :oauth_redirect_base) ||
        FlorinaWeb.Endpoint.url()

    base = String.trim_trailing(base, "/")
    "#{base}/auth/#{provider}/callback"
  end

  @doc """
  Decode (NOT cryptographically verify) the claims of an id_token. Safe here:
  the id_token is received directly from the provider's TLS token endpoint
  (authorization-code flow), never through the browser.
  """
  def decode_claims(id_token) when is_binary(id_token) do
    with [_h, payload, _s] <- String.split(id_token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_id_token}
    end
  end

  def decode_claims(_), do: {:error, :invalid_id_token}

  @doc """
  Return a valid access token for the credential, refreshing if within 60s of
  expiry. A successful refresh is persisted back to the credential row (new
  access token + expiry, and the rotated refresh token when the provider returns
  one) so the next sync reuses it instead of refreshing every time — and so a
  rotated refresh token isn't silently dropped, which would eventually break the
  connection. Persistence runs in the caller's tenant-pinned context.
  """
  def ensure_valid_token(%Credential{} = cred) do
    if token_expired?(cred) do
      case for_credential(cred).refresh_token(cred) do
        {:ok, %{access_token: t} = refreshed} when is_binary(t) and t != "" ->
          persist_refreshed_token(cred, refreshed)
          {:ok, t}

        {:ok, _} ->
          {:error, :token_refresh_empty}

        {:error, reason} ->
          {:error, {:token_refresh_failed, reason}}
      end
    else
      {:ok, cred.access_token}
    end
  end

  defp persist_refreshed_token(%Credential{} = cred, refreshed) do
    attrs =
      %{access_token: refreshed.access_token, expires_at: Map.get(refreshed, :expires_at)}
      |> maybe_put_refresh_token(Map.get(refreshed, :refresh_token))

    case Florina.OAuth.update_credential(cred, attrs) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        require Logger

        Logger.warning(
          "[Provider] could not persist refreshed token for credential=#{cred.id}: " <>
            inspect(changeset.errors)
        )

        :ok
    end
  end

  defp maybe_put_refresh_token(attrs, rt) when is_binary(rt) and rt != "",
    do: Map.put(attrs, :refresh_token, rt)

  defp maybe_put_refresh_token(attrs, _), do: attrs

  defp token_expired?(%Credential{expires_at: nil}), do: false

  defp token_expired?(%Credential{expires_at: exp}),
    do: DateTime.compare(DateTime.utc_now(), DateTime.add(exp, -60, :second)) in [:gt, :eq]
end
