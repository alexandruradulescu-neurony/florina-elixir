defmodule Florina.Integrations.Providers.Google do
  @moduledoc "Google OIDC + Calendar implementation of the provider behaviours."
  @behaviour Florina.Integrations.OAuthProvider
  @behaviour Florina.Integrations.CalendarProvider

  alias Florina.OAuth.Credential
  alias Florina.Integrations.Provider

  @auth_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_uri "https://oauth2.googleapis.com/token"
  @calendar_api "https://www.googleapis.com/calendar/v3"
  @scopes ["openid", "email", "profile", "https://www.googleapis.com/auth/calendar.readonly"]

  @impl Florina.Integrations.OAuthProvider
  def authorize_url(redirect_uri, state) do
    params = %{
      "client_id" => client_id(),
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "scope" => Enum.join(@scopes, " "),
      "access_type" => "offline",
      "include_granted_scopes" => "true",
      "prompt" => "consent",
      "state" => state
    }

    @auth_endpoint <> "?" <> URI.encode_query(params)
  end

  @impl Florina.Integrations.OAuthProvider
  def exchange_code(code, redirect_uri) when is_binary(code) and is_binary(redirect_uri) do
    post_token(%{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => client_id(),
      "client_secret" => client_secret()
    })
  end

  def exchange_code(_, _), do: {:error, :invalid_args}

  @impl Florina.Integrations.OAuthProvider
  def refresh_token(%Credential{refresh_token: rt} = cred) when is_binary(rt) and rt != "" do
    case post_token(%{
           "grant_type" => "refresh_token",
           "refresh_token" => rt,
           "client_id" => cred.client_id || client_id(),
           "client_secret" => cred.client_secret || client_secret()
         }) do
      {:ok, t} ->
        {:ok,
         %{
           access_token: t.access_token,
           refresh_token: t.refresh_token,
           expires_at: expires_at(t.expires_in)
         }}

      err ->
        err
    end
  end

  def refresh_token(_), do: {:error, :no_refresh_token}

  @impl Florina.Integrations.OAuthProvider
  def fetch_identity(tokens) do
    with {:ok, claims} <-
           Provider.verify_id_token(:google, tokens[:id_token] || tokens["id_token"]) do
      {:ok,
       %{
         email: claims["email"],
         email_verified: claims["email_verified"] == true,
         name: claims["name"],
         subject: claims["sub"]
       }}
    end
  end

  @impl Florina.Integrations.CalendarProvider
  def list_events(%Credential{} = cred, time_min, time_max) do
    with {:ok, token} <- Provider.ensure_valid_token(cred) do
      params = %{
        calendarId: "primary",
        timeMin: DateTime.to_iso8601(time_min),
        timeMax: DateTime.to_iso8601(time_max),
        singleEvents: true,
        orderBy: "startTime",
        maxResults: 250
      }

      fetch_pages(token, params, nil, [], 0)
    end
  end

  # Follow Google Calendar's nextPageToken, accumulating events across pages.
  # Capped at 20 pages (~5000 events) as a runaway guard.
  defp fetch_pages(_token, _params, _page_token, acc, page) when page >= 20, do: {:ok, acc}

  defp fetch_pages(token, params, page_token, acc, page) do
    params = if page_token, do: Map.put(params, :pageToken, page_token), else: params

    case Req.get("#{@calendar_api}/calendars/primary/events",
           headers: bearer(token),
           params: params,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: b}} ->
        # Skip all-day events (only a "date", no "dateTime") — they're day
        # markers like "Office"/"Work from office", not real meetings.
        events =
          b
          |> Map.get("items", [])
          |> Enum.reject(&all_day?/1)
          |> Enum.map(&normalize/1)
          |> Enum.reject(&is_nil/1)

        acc = acc ++ events

        case b["nextPageToken"] do
          next when is_binary(next) and next != "" ->
            fetch_pages(token, params, next, acc, page + 1)

          _ ->
            {:ok, acc}
        end

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: s, body: b}} ->
        {:error, {:http, s, b}}

      {:error, r} ->
        {:error, r}
    end
  end

  @impl Florina.Integrations.CalendarProvider
  def get_event(%Credential{} = cred, event_id) when is_binary(event_id) do
    with {:ok, token} <- Provider.ensure_valid_token(cred) do
      case Req.get("#{@calendar_api}/calendars/primary/events/#{URI.encode(event_id)}",
             headers: bearer(token),
             receive_timeout: 15_000
           ) do
        {:ok, %{status: 200, body: b}} -> {:ok, normalize(b)}
        {:ok, %{status: s}} when s in [404, 410] -> {:error, :not_found}
        {:ok, %{status: 401}} -> {:error, :unauthorized}
        {:ok, %{status: s, body: b}} -> {:error, {:http, s, b}}
        {:error, r} -> {:error, r}
      end
    end
  end

  defp post_token(form) do
    case Req.post(@token_uri, form: form, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: b}} ->
        {:ok,
         %{
           access_token: b["access_token"],
           refresh_token: b["refresh_token"],
           expires_in: b["expires_in"],
           scope: b["scope"] || "",
           id_token: b["id_token"]
         }}

      {:ok, %{status: s, body: b}} ->
        {:error, {:http, s, b}}

      {:error, r} ->
        {:error, r}
    end
  end

  defp normalize(item) when is_map(item) do
    start_raw = get_in(item, ["start", "dateTime"]) || get_in(item, ["start", "date"])
    end_raw = get_in(item, ["end", "dateTime"]) || get_in(item, ["end", "date"])
    st = parse_dt(start_raw)
    # Drop the event if it has no id or no parseable start time, rather than
    # inventing "now" — a bad timestamp would otherwise spawn a phantom visit.
    if (id = item["id"]) && st do
      en = parse_dt(end_raw) || DateTime.add(st, 3600, :second)

      %{
        id: id,
        title: item["summary"] || "Untitled Meeting",
        start_time: st,
        end_time: en,
        attendees:
          item |> Map.get("attendees", []) |> Enum.map(& &1["email"]) |> Enum.reject(&is_nil/1),
        description: item["description"] || "",
        location: item["location"],
        status: item["status"] || "confirmed",
        raw: item
      }
    end
  end

  defp normalize(_), do: nil

  # All-day events carry only "date" (no "dateTime") on start.
  defp all_day?(item) when is_map(item), do: is_nil(get_in(item, ["start", "dateTime"]))
  defp all_day?(_), do: true

  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    s = String.replace(s, "Z", "+00:00")

    case DateTime.from_iso8601(s) do
      {:ok, dt, _} ->
        dt

      _ ->
        case Date.from_iso8601(s) do
          {:ok, d} -> DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp bearer(t), do: [{"authorization", "Bearer #{t}"}, {"content-type", "application/json"}]
  defp client_id, do: Application.get_env(:florina, :google_client_id, "")
  defp client_secret, do: Application.get_env(:florina, :google_client_secret, "")
  defp expires_at(nil), do: nil

  defp expires_at(secs),
    do: DateTime.add(DateTime.utc_now(), secs, :second) |> DateTime.truncate(:second)
end
