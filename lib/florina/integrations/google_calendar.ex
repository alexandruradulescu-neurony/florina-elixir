defmodule Florina.Integrations.GoogleCalendar do
  @moduledoc """
  Google Calendar API v3 client — per-user OAuth creds.

  Behaviour callbacks:
  - `list_events/3` — list calendar events in a time window for a user.
  - `create_watch/3` — set up a push-notification channel (Watch API).
  - `stop_watch/3` — stop a push-notification channel.
  - `refresh_token/1` — exchange a refresh token for a new access token.

  The implementation is chosen via:

      config :florina, :google_calendar_client, Florina.Integrations.GoogleCalendar

  Tests swap in `Florina.Integrations.GoogleCalendar.Stub`.

  Auth: per-user OAuth credentials from `Florina.Calendar.get_credential_for_user/1`.
  Global secrets (client_id, client_secret) come from config.

  Deferred from Django source:
  - `handle_google_calendar_notification/2` (webhook notification handler) —
    lives in the webhook controller (already ported inbound path).
  - `sync_google_calendar/4` (full sync with Visit updates) — orchestration
    that belongs in services/workers, not the HTTP client layer. This module
    provides the raw `list_events` primitive; the Oban worker in Backend Phase 4
    will call it.
  - `get_auth_url/2` and `handle_auth_callback/3` (OAuth flow) — belong in the
    LiveView / controller layer, not the HTTP client. They'll be added when the
    Google OAuth flow is wired up.
  """

  alias Florina.Calendar.GoogleOauthCredential

  @callback list_events(GoogleOauthCredential.t(), DateTime.t(), DateTime.t()) ::
              {:ok, [map()]} | {:error, term()}

  @callback create_watch(GoogleOauthCredential.t(), String.t(), String.t()) ::
              {:ok, %{channel_id: String.t(), resource_id: String.t(), expiration: DateTime.t()}}
              | {:error, term()}

  @callback stop_watch(GoogleOauthCredential.t(), String.t(), String.t()) ::
              :ok | {:error, term()}

  @callback refresh_token(GoogleOauthCredential.t()) ::
              {:ok, %{access_token: String.t(), expires_at: DateTime.t() | nil}}
              | {:error, term()}

  @callback exchange_code(String.t(), String.t()) ::
              {:ok,
               %{
                 access_token: String.t(),
                 refresh_token: String.t(),
                 expires_in: integer() | nil,
                 scope: String.t(),
                 token_type: String.t()
               }}
              | {:error, term()}

  # ---------------------------------------------------------------------------
  # Resolve the configured implementation
  # ---------------------------------------------------------------------------

  @doc false
  def impl do
    Application.get_env(:florina, :google_calendar_client, __MODULE__)
  end

  @doc """
  List events from the user's primary calendar in the given time range.

  Returns `{:ok, [event_map]}` where each map has at least:
  `id`, `title`, `start_time` (DateTime), `end_time` (DateTime),
  `attendees` ([email strings]), `description`, `raw`.
  """
  def list_events(cred, time_min, time_max),
    do: impl().do_list_events(cred, time_min, time_max)

  @doc """
  Create a Google Calendar push-notification watch channel.

  - `cred`: OAuth credential for the user.
  - `webhook_url`: Public URL where Google sends notifications.
  - `channel_token`: Random secret to echo back in notifications (CWE-345 mitigation).

  Returns `{:ok, %{channel_id, resource_id, expiration}}`.
  """
  def create_watch(cred, webhook_url, channel_token),
    do: impl().do_create_watch(cred, webhook_url, channel_token)

  @doc """
  Stop a push-notification watch channel.

  - `channel_id`: UUID that was used when calling `create_watch`.
  - `resource_id`: The `resourceId` returned by Google when the watch was created.
  """
  def stop_watch(cred, channel_id, resource_id),
    do: impl().do_stop_watch(cred, channel_id, resource_id)

  @doc "Refresh an expired OAuth access token. Returns the new access token and expiry."
  def refresh_token(cred), do: impl().do_refresh_token(cred)

  @doc """
  Exchange an authorization code for OAuth tokens.

  Called during the OAuth callback after the user grants consent.
  Returns the access token, refresh token, expiry, scope, and token type.
  """
  def exchange_code(code, redirect_uri), do: impl().do_exchange_code(code, redirect_uri)

  # ---------------------------------------------------------------------------
  # Real implementation (called via do_* wrappers to avoid name collision with
  # the delegating public API above when this module is its own impl).
  # ---------------------------------------------------------------------------

  @calendar_api "https://www.googleapis.com/calendar/v3"
  @token_uri "https://oauth2.googleapis.com/token"

  @doc false
  def do_list_events(%GoogleOauthCredential{} = cred, time_min, time_max) do
    with {:ok, access_token} <- ensure_valid_token(cred) do
      params = %{
        calendarId: "primary",
        timeMin: DateTime.to_iso8601(time_min),
        timeMax: DateTime.to_iso8601(time_max),
        singleEvents: true,
        orderBy: "startTime"
      }

      case Req.get("#{@calendar_api}/calendars/primary/events",
             headers: bearer_headers(access_token),
             params: params,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: body}} ->
          events =
            body
            |> Map.get("items", [])
            |> Enum.map(&normalize_event/1)
            |> Enum.reject(&is_nil/1)

          {:ok, events}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  def do_create_watch(%GoogleOauthCredential{} = cred, webhook_url, channel_token) do
    with {:ok, access_token} <- ensure_valid_token(cred) do
      channel_id = generate_uuid()

      body = %{
        "id" => channel_id,
        "type" => "web_hook",
        "address" => webhook_url,
        "token" => channel_token
      }

      case Req.post("#{@calendar_api}/calendars/primary/events/watch",
             headers: bearer_headers(access_token),
             json: body,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: resp}} ->
          resource_id = resp["resourceId"]

          if resource_id do
            expiration =
              case resp["expiration"] do
                nil ->
                  DateTime.add(DateTime.utc_now(), 6 * 24 * 3600, :second)

                ms_str ->
                  ms = String.to_integer("#{ms_str}")
                  DateTime.from_unix!(div(ms, 1000))
              end

            {:ok, %{channel_id: channel_id, resource_id: resource_id, expiration: expiration}}
          else
            {:error, :missing_resource_id}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  def do_stop_watch(%GoogleOauthCredential{} = cred, channel_id, resource_id) do
    with {:ok, access_token} <- ensure_valid_token(cred) do
      body = %{"id" => channel_id, "resourceId" => resource_id}

      case Req.post("#{@calendar_api}/channels/stop",
             headers: bearer_headers(access_token),
             json: body,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: status}} when status in [200, 204] -> :ok
        {:ok, %{status: 404}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def do_refresh_token(%GoogleOauthCredential{refresh_token: rt} = cred)
      when is_binary(rt) and rt != "" do
    client_id = cred.client_id || Application.get_env(:florina, :google_client_id, "")
    client_secret = cred.client_secret || Application.get_env(:florina, :google_client_secret, "")

    form = %{
      "grant_type" => "refresh_token",
      "refresh_token" => rt,
      "client_id" => client_id,
      "client_secret" => client_secret
    }

    case Req.post(@token_uri, form: form, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: resp}} ->
        expires_at =
          case resp["expires_in"] do
            nil -> nil
            secs -> DateTime.add(DateTime.utc_now(), secs, :second)
          end

        {:ok, %{access_token: resp["access_token"], expires_at: expires_at}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_refresh_token(_cred), do: {:error, :no_refresh_token}

  @doc false
  def do_exchange_code(code, redirect_uri) when is_binary(code) and is_binary(redirect_uri) do
    client_id = Application.get_env(:florina, :google_client_id, "")
    client_secret = Application.get_env(:florina, :google_client_secret, "")

    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => client_id,
      "client_secret" => client_secret
    }

    case Req.post(@token_uri, form: form, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok,
         %{
           access_token: resp["access_token"],
           refresh_token: resp["refresh_token"],
           expires_in: resp["expires_in"],
           scope: resp["scope"] || "",
           token_type: resp["token_type"] || "Bearer"
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_exchange_code(_code, _redirect_uri), do: {:error, :invalid_args}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp ensure_valid_token(%GoogleOauthCredential{} = cred) do
    if token_expired?(cred) do
      case do_refresh_token(cred) do
        {:ok, %{access_token: token}} when is_binary(token) and token != "" ->
          {:ok, token}

        {:ok, _} ->
          {:error, :token_refresh_empty}

        {:error, reason} ->
          {:error, {:token_refresh_failed, reason}}
      end
    else
      {:ok, cred.token}
    end
  end

  defp token_expired?(%GoogleOauthCredential{expires_at: nil}), do: false

  defp token_expired?(%GoogleOauthCredential{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), DateTime.add(expires_at, -60, :second)) in [:gt, :eq]
  end

  defp bearer_headers(token) do
    [{"authorization", "Bearer #{token}"}, {"content-type", "application/json"}]
  end

  defp normalize_event(item) when is_map(item) do
    event_id = item["id"]

    if event_id do
      start_raw = get_in(item, ["start", "dateTime"]) || get_in(item, ["start", "date"])
      end_raw = get_in(item, ["end", "dateTime"]) || get_in(item, ["end", "date"])

      start_time = parse_datetime(start_raw) || DateTime.utc_now()
      end_time = parse_datetime(end_raw) || DateTime.add(start_time, 3600, :second)

      attendees =
        item
        |> Map.get("attendees", [])
        |> Enum.map(& &1["email"])
        |> Enum.reject(&is_nil/1)

      %{
        id: event_id,
        title: item["summary"] || "Untitled Meeting",
        start_time: start_time,
        end_time: end_time,
        attendees: attendees,
        description: item["description"] || "",
        raw: item
      }
    end
  end

  defp normalize_event(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    str = String.replace(str, "Z", "+00:00")

    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp generate_uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::30, e::48>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c::12, 2::2, d::30, e::48>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<p1::8-bytes, p2::4-bytes, p3::4-bytes, p4::4-bytes, p5::12-bytes>> = hex
      "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
    end)
  end
end
