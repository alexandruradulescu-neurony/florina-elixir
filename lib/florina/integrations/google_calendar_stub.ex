defmodule Florina.Integrations.GoogleCalendar.Stub do
  @moduledoc """
  Test stub for `Florina.Integrations.GoogleCalendar`.

  Responses are controlled via the process dictionary.

  Usage:

      alias Florina.Integrations.GoogleCalendar.Stub, as: GCalStub

      GCalStub.set_list_events({:ok, [%{id: "evt1", title: "Meeting", ...}]})
      GCalStub.set_create_watch({:ok, %{channel_id: "ch1", resource_id: "res1", expiration: ~U[2026-07-01 00:00:00Z]}})

  Configured in test.exs:

      config :florina, :google_calendar_client, Florina.Integrations.GoogleCalendar.Stub
  """

  # The dispatch pattern in GoogleCalendar calls do_* on the resolved impl module.
  def do_list_events(_cred, _time_min, _time_max) do
    Process.get(:gcal_stub_list_events, {:ok, []})
  end

  def do_create_watch(_cred, _webhook_url, _channel_token) do
    default = {
      :ok,
      %{
        channel_id: "stub_channel_id",
        resource_id: "stub_resource_id",
        expiration: DateTime.add(DateTime.utc_now(), 6 * 24 * 3600, :second)
      }
    }

    Process.get(:gcal_stub_create_watch, default)
  end

  def do_stop_watch(_cred, _channel_id, _resource_id) do
    Process.get(:gcal_stub_stop_watch, :ok)
  end

  def do_refresh_token(_cred) do
    default = {:ok, %{access_token: "stub_access_token", expires_at: nil}}
    Process.get(:gcal_stub_refresh_token, default)
  end

  def do_exchange_code(_code, _redirect_uri) do
    default =
      {:ok,
       %{
         access_token: "stub_access_token",
         refresh_token: "stub_refresh_token",
         expires_in: 3600,
         scope: "https://www.googleapis.com/auth/calendar.readonly",
         token_type: "Bearer"
       }}

    Process.get(:gcal_stub_exchange_code, default)
  end

  # ---------------------------------------------------------------------------
  # Helpers for tests
  # ---------------------------------------------------------------------------

  def set_list_events(response), do: Process.put(:gcal_stub_list_events, response)
  def set_create_watch(response), do: Process.put(:gcal_stub_create_watch, response)
  def set_stop_watch(response), do: Process.put(:gcal_stub_stop_watch, response)
  def set_refresh_token(response), do: Process.put(:gcal_stub_refresh_token, response)
  def set_exchange_code(response), do: Process.put(:gcal_stub_exchange_code, response)

  def reset do
    Process.delete(:gcal_stub_list_events)
    Process.delete(:gcal_stub_create_watch)
    Process.delete(:gcal_stub_stop_watch)
    Process.delete(:gcal_stub_refresh_token)
    Process.delete(:gcal_stub_exchange_code)
  end
end
