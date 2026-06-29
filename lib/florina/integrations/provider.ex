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

  def sign_state(endpoint_or_conn, tenant_slug, provider, nonce) do
    Phoenix.Token.sign(endpoint_or_conn, @state_salt, %{
      tenant_slug: tenant_slug,
      provider: to_string(provider),
      nonce: nonce
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

  @id_token_leeway_seconds 60

  @doc """
  Validate an id_token's registered claims and return them, or `{:error, reason}`.

  We do NOT verify the JWS signature: in the authorization-code flow the id_token
  is fetched directly from the provider's token endpoint over TLS, so per OIDC
  Core §3.1.3.7 the TLS server identity authenticates the issuer in place of the
  signature. We DO validate the claims TLS doesn't cover — audience (the token
  was issued for THIS app, not another client), issuer (it came from the expected
  provider), and expiry — which the previous decode-only path skipped.
  """
  def verify_id_token(provider, id_token) when is_atom(provider) and is_binary(id_token) do
    with {:ok, claims} <- decode_claims(id_token),
         :ok <- validate_audience(provider, claims),
         :ok <- validate_issuer(provider, claims),
         :ok <- validate_expiry(claims) do
      {:ok, claims}
    end
  end

  def verify_id_token(_provider, _id_token), do: {:error, :invalid_id_token}

  @doc """
  Decode (NOT cryptographically verify) the claims of an id_token. Prefer
  `verify_id_token/2`, which also validates audience/issuer/expiry.
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

  # aud must equal our OAuth client id for that provider (it may be a string or
  # a list of audiences). A missing client-id config fails closed.
  defp validate_audience(provider, claims) do
    expected = audience(provider)

    cond do
      expected in [nil, ""] -> {:error, :missing_audience_config}
      expected in List.wrap(claims["aud"]) -> :ok
      true -> {:error, :bad_audience}
    end
  end

  defp audience(:google), do: Application.get_env(:florina, :google_client_id)
  defp audience(:microsoft), do: Application.get_env(:florina, :microsoft_client_id)

  defp validate_issuer(:google, claims) do
    if claims["iss"] in ["https://accounts.google.com", "accounts.google.com"],
      do: :ok,
      else: {:error, :bad_issuer}
  end

  # Entra ID issuer is tenant-specific (https://login.microsoftonline.com/<tid>/v2.0),
  # so match the host + the /v2.0 suffix rather than a fixed string.
  defp validate_issuer(:microsoft, claims) do
    case URI.parse(to_string(claims["iss"])) do
      %URI{host: "login.microsoftonline.com", path: path} when is_binary(path) ->
        if String.ends_with?(path, "/v2.0"), do: :ok, else: {:error, :bad_issuer}

      _ ->
        {:error, :bad_issuer}
    end
  end

  defp validate_expiry(claims) do
    now = System.system_time(:second)

    case claims["exp"] do
      exp when is_integer(exp) ->
        if exp + @id_token_leeway_seconds >= now, do: :ok, else: {:error, :expired}

      _ ->
        {:error, :missing_expiry}
    end
  end

  @doc """
  Return a valid access token for the credential, refreshing if within 60s of
  expiry. A successful refresh is persisted back to the credential row (new
  access token + expiry, and the rotated refresh token when the provider returns
  one) so the next sync reuses it instead of refreshing every time — and so a
  rotated refresh token isn't silently dropped, which would eventually break the
  connection. Persistence runs in the caller's tenant-pinned context.
  """
  def ensure_valid_token(%Credential{} = cred) do
    # Refresh OUTSIDE any DB transaction — the external HTTP refresh must not run
    # while holding a row lock / DB connection (that would starve the pool under
    # load). Concurrent refreshes for one credential are rare and last-write-wins;
    # Google refresh tokens don't rotate and Microsoft tolerates it.
    if token_expired?(cred) do
      refresh_and_persist(cred)
    else
      {:ok, cred.access_token}
    end
  end

  defp refresh_and_persist(%Credential{} = cred) do
    case for_credential(cred).refresh_token(cred) do
      {:ok, %{access_token: t} = refreshed} when is_binary(t) and t != "" ->
        persist_refreshed_token(cred, refreshed)
        {:ok, t}

      {:ok, _} ->
        {:error, :token_refresh_empty}

      {:error, reason} ->
        {:error, {:token_refresh_failed, reason}}
    end
  end

  defp persist_refreshed_token(%Credential{} = cred, refreshed) do
    require Logger

    attrs =
      %{access_token: refreshed.access_token, expires_at: Map.get(refreshed, :expires_at)}
      |> maybe_put_refresh_token(Map.get(refreshed, :refresh_token))

    # Conditional on the stored refresh token still being the one we refreshed
    # from — so a concurrent sync that already rotated it isn't clobbered.
    case Florina.OAuth.persist_refreshed_token(cred, attrs, cred.refresh_token) do
      {:ok, :stale} ->
        Logger.info(
          "[Provider] credential=#{cred.id} refresh token rotated concurrently; kept newer value"
        )

        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Provider] could not persist refreshed token for credential=#{cred.id}: " <>
            inspect(reason)
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
