defmodule Florina.Integrations.Providers.Microsoft do
  @moduledoc """
  Microsoft identity platform (Entra ID) + Microsoft Graph Calendar implementation.

  Uses a multi-tenant app by default (`MICROSOFT_TENANT=common`) so agents from
  any customer's Microsoft 365 directory can sign in. Identity comes from the
  id_token claims; calendar from Graph `/me/calendarView`.
  """
  @behaviour Florina.Integrations.OAuthProvider
  @behaviour Florina.Integrations.CalendarProvider

  alias Florina.OAuth.Credential
  alias Florina.Integrations.Provider

  @graph "https://graph.microsoft.com/v1.0"
  @scopes ["openid", "profile", "email", "offline_access", "Calendars.Read"]

  @impl Florina.Integrations.OAuthProvider
  def authorize_url(redirect_uri, state) do
    params = %{
      "client_id" => client_id(),
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "response_mode" => "query",
      "scope" => Enum.join(@scopes, " "),
      "prompt" => "select_account",
      "state" => state
    }

    authorize_endpoint() <> "?" <> URI.encode_query(params)
  end

  @impl Florina.Integrations.OAuthProvider
  def exchange_code(code, redirect_uri) when is_binary(code) and is_binary(redirect_uri) do
    post_token(%{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => client_id(),
      "client_secret" => client_secret(),
      "scope" => Enum.join(@scopes, " ")
    })
  end

  def exchange_code(_, _), do: {:error, :invalid_args}

  @impl Florina.Integrations.OAuthProvider
  def refresh_token(%Credential{refresh_token: rt} = cred) when is_binary(rt) and rt != "" do
    case post_token(%{
           "grant_type" => "refresh_token",
           "refresh_token" => rt,
           "client_id" => cred.client_id || client_id(),
           "client_secret" => cred.client_secret || client_secret(),
           "scope" => Enum.join(@scopes, " ")
         }) do
      {:ok, t} -> {:ok, %{access_token: t.access_token, expires_at: expires_at(t.expires_in)}}
      err -> err
    end
  end

  def refresh_token(_), do: {:error, :no_refresh_token}

  @impl Florina.Integrations.OAuthProvider
  def fetch_identity(tokens) do
    with {:ok, claims} <- Provider.decode_claims(tokens[:id_token] || tokens["id_token"]) do
      email = claims["email"] || claims["preferred_username"]

      {:ok,
       %{
         email: email,
         email_verified: is_binary(email),
         name: claims["name"],
         subject: claims["oid"] || claims["sub"]
       }}
    end
  end

  @impl Florina.Integrations.CalendarProvider
  def list_events(%Credential{} = cred, time_min, time_max) do
    with {:ok, token} <- Provider.ensure_valid_token(cred) do
      params = %{
        "startDateTime" => DateTime.to_iso8601(time_min),
        "endDateTime" => DateTime.to_iso8601(time_max),
        "$orderby" => "start/dateTime",
        "$top" => "250"
      }

      headers = [
        {"authorization", "Bearer #{token}"},
        {"Prefer", ~s(outlook.timezone="UTC")}
      ]

      case Req.get("#{@graph}/me/calendarView",
             headers: headers,
             params: params,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: b}} ->
          {:ok, b |> Map.get("value", []) |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: s, body: b}} ->
          {:error, {:http, s, b}}

        {:error, r} ->
          {:error, r}
      end
    end
  end

  defp tenant,
    do:
      Application.get_env(:florina, :microsoft_tenant) ||
        System.get_env("MICROSOFT_TENANT") || "common"

  defp authorize_endpoint,
    do: "https://login.microsoftonline.com/#{tenant()}/oauth2/v2.0/authorize"

  defp token_endpoint, do: "https://login.microsoftonline.com/#{tenant()}/oauth2/v2.0/token"
  defp client_id, do: Application.get_env(:florina, :microsoft_client_id, "")
  defp client_secret, do: Application.get_env(:florina, :microsoft_client_secret, "")

  defp post_token(form) do
    case Req.post(token_endpoint(), form: form, receive_timeout: 15_000) do
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
    if id = item["id"] do
      st = parse_dt(get_in(item, ["start", "dateTime"])) || DateTime.utc_now()
      en = parse_dt(get_in(item, ["end", "dateTime"])) || DateTime.add(st, 3600, :second)

      attendees =
        item
        |> Map.get("attendees", [])
        |> Enum.map(&get_in(&1, ["emailAddress", "address"]))
        |> Enum.reject(&is_nil/1)

      %{
        id: id,
        title: item["subject"] || "Untitled Meeting",
        start_time: st,
        end_time: en,
        attendees: attendees,
        description: item["bodyPreview"] || "",
        location: get_in(item, ["location", "displayName"]),
        status: if(item["isCancelled"], do: "cancelled", else: "confirmed"),
        raw: item
      }
    end
  end

  defp normalize(_), do: nil

  # Graph returns e.g. "2026-06-25T10:00:00.0000000" (UTC, per the Prefer header), no offset.
  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    case NaiveDateTime.from_iso8601(String.slice(s, 0, 19)) do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  defp expires_at(nil), do: nil

  defp expires_at(secs),
    do: DateTime.add(DateTime.utc_now(), secs, :second) |> DateTime.truncate(:second)
end
