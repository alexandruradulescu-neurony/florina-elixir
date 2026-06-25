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

  def redirect_uri(tenant_slug, provider) do
    base =
      System.get_env("OAUTH_REDIRECT_BASE") ||
        Application.get_env(:florina, :oauth_redirect_base) ||
        FlorinaWeb.Endpoint.url()

    base = String.trim_trailing(base, "/")
    "#{base}/t/#{tenant_slug}/auth/#{provider}/callback"
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

  @doc "Return a valid access token for the credential, refreshing if within 60s of expiry."
  def ensure_valid_token(%Credential{} = cred) do
    if token_expired?(cred) do
      case for_credential(cred).refresh_token(cred) do
        {:ok, %{access_token: t}} when is_binary(t) and t != "" -> {:ok, t}
        {:ok, _} -> {:error, :token_refresh_empty}
        {:error, reason} -> {:error, {:token_refresh_failed, reason}}
      end
    else
      {:ok, cred.access_token}
    end
  end

  defp token_expired?(%Credential{expires_at: nil}), do: false

  defp token_expired?(%Credential{expires_at: exp}),
    do: DateTime.compare(DateTime.utc_now(), DateTime.add(exp, -60, :second)) in [:gt, :eq]
end
