defmodule Florina.Integrations.GoogleOAuth do
  @moduledoc """
  Helpers for building the Google OAuth 2.0 authorization URL and signing/verifying
  the `state` parameter used to protect the callback.

  The `state` is a `Phoenix.Token` signed with the endpoint secret, encoding
  `%{tenant_slug: slug, agent_id: id}`. The callback verifies it before trusting
  any `code` from Google's redirect.

  Scopes requested:
  - `https://www.googleapis.com/auth/calendar.readonly` — read events
  - `openid`, `email`, `profile` — basic identity (useful for future agent-identity checks)
  """

  @auth_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @scopes [
    "https://www.googleapis.com/auth/calendar.readonly",
    "openid",
    "email",
    "profile"
  ]

  @doc """
  Build the Google consent-screen URL.

  - `redirect_uri` — the callback URL registered in Google Cloud Console
  - `state` — a signed Phoenix.Token string (opaque to Google; echoed back on callback)

  Returns the full URL string to redirect the user to.
  """
  def auth_url(redirect_uri, state) do
    client_id = Application.get_env(:florina, :google_client_id, "")

    params = %{
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "scope" => Enum.join(@scopes, " "),
      "access_type" => "offline",
      "prompt" => "consent",
      "state" => state
    }

    @auth_endpoint <> "?" <> URI.encode_query(params)
  end

  @doc """
  Sign a state map into a Phoenix.Token string.

  The token encodes `%{tenant_slug: slug, agent_id: agent_id}` and is valid for
  600 seconds — long enough for a user to complete the consent screen.
  """
  def sign_state(endpoint_or_conn, tenant_slug, agent_id) do
    Phoenix.Token.sign(endpoint_or_conn, "google_oauth_state", %{
      tenant_slug: tenant_slug,
      agent_id: agent_id
    })
  end

  @doc """
  Verify a state string and return `{:ok, %{tenant_slug, agent_id}}` or `{:error, reason}`.

  `max_age` defaults to 600 seconds.
  """
  def verify_state(endpoint_or_conn, state, max_age \\ 600) do
    Phoenix.Token.verify(endpoint_or_conn, "google_oauth_state", state, max_age: max_age)
  end

  @doc """
  Build the redirect URI for the OAuth callback.

  Uses `GOOGLE_REDIRECT_BASE` env var when set, falling back to the PHX_HOST-derived
  endpoint URL. Tenant slug is embedded in the path so `ResolveTenant` can pin the DB.

  Shape: `https://<host>/t/<tenant_slug>/calendar/callback`
  """
  def redirect_uri(tenant_slug) do
    base =
      System.get_env("GOOGLE_REDIRECT_BASE") ||
        Application.get_env(:florina, :google_redirect_base) ||
        FlorinaWeb.Endpoint.url()

    base = String.trim_trailing(base, "/")
    "#{base}/t/#{tenant_slug}/calendar/callback"
  end
end
