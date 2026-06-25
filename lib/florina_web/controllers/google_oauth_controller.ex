defmodule FlorinaWeb.GoogleOAuthController do
  @moduledoc """
  Handles the Google Calendar OAuth 2.0 authorization-code flow.

  Two actions:

  - `connect/2` (GET `/t/:tenant_slug/calendar/connect?agent_id=<id>`)
    Operator-triggered. Builds a signed state token encoding `{tenant_slug, agent_id}`
    and redirects the browser to Google's consent screen. Protected by dashboard_auth.

  - `callback/2` (GET `/t/:tenant_slug/calendar/callback`)
    Google redirects here after the user grants (or denies) consent. Verifies the
    signed state; exchanges the authorization code for tokens; upserts the
    `GoogleOauthCredential` for the agent in the tenant's database.
    Protected by the signed state (not dashboard_auth — Google cannot send Basic-Auth).

  ## Constraints (documented, not solved here)

  - **Agent identity**: there is no per-agent login yet, so `agent_id` is passed
    explicitly as a query param (operator-triggered flow). A self-service flow requires
    agent auth and belongs to the future manager app.
  - **Google Cloud setup**: the redirect URI and client credentials must be configured
    by the operator in Google Cloud Console and set as env vars before the flow
    round-trips in production.
  """

  use FlorinaWeb, :controller
  require Logger

  alias Florina.Calendar
  alias Florina.Integrations.{GoogleCalendar, GoogleOAuth}

  # ---------------------------------------------------------------------------
  # connect — redirect to Google consent screen
  # ---------------------------------------------------------------------------

  @doc """
  Initiate the OAuth flow for a given agent.

  Expects `agent_id` as a query param. Redirects to Google's consent screen with a
  signed state token. Protected by dashboard_auth (see router).
  """
  def connect(conn, %{"agent_id" => agent_id} = _params) do
    tenant_slug = conn.assigns.tenant.slug
    redirect_uri = GoogleOAuth.redirect_uri(tenant_slug)
    state = GoogleOAuth.sign_state(conn, tenant_slug, agent_id)
    url = GoogleOAuth.auth_url(redirect_uri, state)
    redirect(conn, external: url)
  end

  def connect(conn, _params) do
    conn
    |> put_flash(:error, "agent_id is required")
    |> redirect(to: "/")
  end

  # ---------------------------------------------------------------------------
  # callback — Google redirects here with code + state
  # ---------------------------------------------------------------------------

  @doc """
  Handle the Google OAuth callback.

  1. Verify the signed state (rejects stale/tampered requests).
  2. Exchange the code for tokens via `GoogleCalendar.exchange_code/2`.
  3. Upsert the `GoogleOauthCredential` for the agent in the tenant DB.
  4. Redirect with a success or error flash.
  """
  def callback(conn, %{"code" => code, "state" => state}) do
    case GoogleOAuth.verify_state(conn, state) do
      {:ok, %{tenant_slug: tenant_slug, agent_id: agent_id}} ->
        handle_code_exchange(conn, code, tenant_slug, to_string(agent_id))

      {:error, reason} ->
        Logger.warning("Google OAuth state verification failed: #{inspect(reason)}")

        conn
        |> put_status(400)
        |> put_flash(:error, "OAuth state invalid or expired. Please try connecting again.")
        |> redirect(to: "/")
    end
  end

  def callback(conn, %{"error" => error}) do
    Logger.warning("Google OAuth denied by user or error: #{error}")

    conn
    |> put_flash(:error, "Google authorization was denied: #{error}")
    |> redirect(to: "/")
  end

  def callback(conn, _params) do
    conn
    |> put_status(400)
    |> put_flash(:error, "Invalid callback — missing code or state.")
    |> redirect(to: "/")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp handle_code_exchange(conn, code, tenant_slug, agent_id) do
    redirect_uri = GoogleOAuth.redirect_uri(tenant_slug)

    case GoogleCalendar.exchange_code(code, redirect_uri) do
      {:ok, tokens} ->
        upsert_credential(conn, agent_id, tokens)

      {:error, reason} ->
        Logger.error("Google OAuth code exchange failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Failed to exchange authorization code with Google.")
        |> redirect(to: "/")
    end
  end

  defp upsert_credential(conn, agent_id, tokens) do
    client_id = Application.get_env(:florina, :google_client_id, "")
    client_secret = Application.get_env(:florina, :google_client_secret, "")

    expires_at =
      case tokens.expires_in do
        nil -> nil
        secs -> DateTime.add(DateTime.utc_now(), secs, :second) |> DateTime.truncate(:second)
      end

    scopes =
      tokens.scope
      |> String.split(" ", trim: true)

    attrs = %{
      user_id: agent_id,
      token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      client_id: client_id,
      client_secret: client_secret,
      scopes: scopes,
      expires_at: expires_at
    }

    result =
      case Calendar.get_credential_for_user(agent_id) do
        nil -> Calendar.create_credential(attrs)
        existing -> Calendar.update_credential(existing, attrs)
      end

    case result do
      {:ok, _cred} ->
        conn
        |> put_flash(:info, "Google Calendar connected successfully.")
        |> redirect(to: ~p"/t/#{conn.assigns.tenant.slug}/calls")

      {:error, changeset} ->
        Logger.error("Failed to store Google OAuth credential: #{inspect(changeset)}")

        conn
        |> put_flash(:error, "Connected but failed to save credentials. Please try again.")
        |> redirect(to: "/")
    end
  end
end
