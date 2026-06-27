defmodule Florina.Integrations.Providers.Stub do
  @moduledoc """
  Process-dict-controlled provider stub for tests; used for BOTH the google and
  microsoft config keys. Defaults succeed with an allowed-domain identity.
  """
  @behaviour Florina.Integrations.OAuthProvider
  @behaviour Florina.Integrations.CalendarProvider

  def authorize_url(redirect_uri, state),
    do:
      "https://stub.test/authorize?redirect_uri=#{URI.encode_www_form(redirect_uri)}&state=#{state}"

  def exchange_code(_code, _redirect_uri) do
    Process.get(
      :oauth_stub_exchange_code,
      {:ok,
       %{
         access_token: "stub_access",
         refresh_token: "stub_refresh",
         expires_in: 3600,
         scope: "openid email",
         id_token: nil
       }}
    )
  end

  def refresh_token(_cred),
    do:
      Process.get(
        :oauth_stub_refresh_token,
        {:ok, %{access_token: "stub_access2", expires_at: nil}}
      )

  def fetch_identity(_tokens) do
    Process.get(
      :oauth_stub_identity,
      {:ok,
       %{email: "agent@leadder.com", email_verified: true, name: "Agent Stub", subject: "sub-1"}}
    )
  end

  def list_events(_cred, _min, _max), do: Process.get(:oauth_stub_list_events, {:ok, []})

  # Default is a non-:not_found error so the freshness check proceeds (places the
  # call) in tests that don't opt into it. Tests exercising freshness set it.
  def get_event(_cred, _id), do: Process.get(:oauth_stub_get_event, {:error, :not_configured})

  def set_exchange_code(r), do: Process.put(:oauth_stub_exchange_code, r)
  def set_refresh_token(r), do: Process.put(:oauth_stub_refresh_token, r)
  def set_identity(r), do: Process.put(:oauth_stub_identity, r)
  def set_list_events(r), do: Process.put(:oauth_stub_list_events, r)
  def set_get_event(r), do: Process.put(:oauth_stub_get_event, r)

  def reset do
    Enum.each(
      [
        :oauth_stub_exchange_code,
        :oauth_stub_refresh_token,
        :oauth_stub_identity,
        :oauth_stub_list_events,
        :oauth_stub_get_event
      ],
      &Process.delete/1
    )
  end
end
