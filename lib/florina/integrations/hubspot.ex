defmodule Florina.Integrations.Hubspot do
  @moduledoc """
  HubSpot CRM API client, exposing the same surface as `Florina.Integrations.Pipedrive`
  so the two are interchangeable behind `Florina.Integrations.CRM`.

  HubSpot's "company" maps to a Pipedrive "organization"; contacts map to persons,
  deals to deals, notes + engagements (calls/emails/meetings) to interaction
  history. Every `do_*` function translates HubSpot's `{id, properties}` shape into
  the **Pipedrive-shaped** maps that `Florina.Integrations.ClientSync` already
  consumes — string keys; email/phone as `[%{"value" => ..., "primary" => true}]`;
  deal `status` in the Pipedrive vocabulary ("open"/"won"/"lost") — so the sync
  orchestration is unchanged. Mappers tolerate records missing `properties`/`id`
  (archived or permission-limited objects) by skipping them rather than crashing.

  Auth: per-tenant **Private App access token** from the tenant settings
  (`Settings.hubspot_api_token`), sent as `Authorization: Bearer <token>`.
  Base URL: `https://api.hubapi.com` (fixed — no per-tenant domain).

  The implementation is chosen via `config :florina, :hubspot_client, …`; tests
  swap in `Florina.Integrations.Hubspot.Stub`.

  NOTE: untested against a live HubSpot account — verify with a real Private App
  token before relying on it in production. Pipedrive is the default provider.
  """

  require Logger

  alias Florina.Integrations.CRM
  alias Florina.Strings

  @base_url "https://api.hubapi.com"
  # Runaway guard for company pagination (50 * 100 = 5000 companies/run).
  @max_pages 50
  @page_size 100
  # HubSpot batch-read accepts at most 100 inputs per request.
  @batch_limit 100

  @company_props ~w(name domain industry)
  @contact_props ~w(firstname lastname email phone)
  @deal_props ~w(dealname amount dealstage deal_currency_code hs_is_closed hs_is_closed_won)
  @note_props ~w(hs_note_body hs_timestamp hs_createdate)

  # HubSpot engagement object types pulled into interaction history, with the
  # Pipedrive-style activity label and the properties to request for each.
  @engagement_types [
    {"calls", "call", ~w(hs_call_title hs_call_body hs_timestamp)},
    {"emails", "email", ~w(hs_email_subject hs_email_text hs_timestamp)},
    {"meetings", "meeting",
     ~w(hs_meeting_title hs_meeting_body hs_meeting_start_time hs_timestamp)}
  ]

  # ---------------------------------------------------------------------------
  # Public facade — delegates to the configured implementation (stub in tests)
  # ---------------------------------------------------------------------------

  @doc false
  def impl, do: Application.get_env(:florina, :hubspot_client, __MODULE__)

  def list_organizations, do: impl().do_list_organizations()
  def get_organization(id), do: impl().do_get_organization(id)
  def get_organization_persons(id), do: impl().do_get_organization_persons(id)
  def get_organization_deals(id), do: impl().do_get_organization_deals(id)
  def get_organization_notes(id), do: impl().do_get_organization_notes(id)
  def get_organization_activities(id), do: impl().do_get_organization_activities(id)

  # ---------------------------------------------------------------------------
  # Real implementation (HubSpot CRM API v3/v4)
  # ---------------------------------------------------------------------------

  def do_list_organizations do
    with {:ok, token} <- token() do
      fetch_companies(token, nil, [], 0)
    end
  end

  def do_get_organization(id) do
    with {:ok, token} <- token() do
      case get(token, "/crm/v3/objects/companies/#{id}",
             properties: Enum.join(@company_props, ",")
           ) do
        {:ok, %{} = obj} -> {:ok, company_to_org(obj)}
        {:error, {:http, 404, _}} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def do_get_organization_persons(id) do
    with {:ok, token} <- token(),
         {:ok, ids} <- associated_ids(token, "companies", id, "contacts"),
         {:ok, contacts} <- batch_read(token, "contacts", ids, @contact_props) do
      {:ok, map_skip(contacts, &contact_to_person/1)}
    end
  end

  def do_get_organization_deals(id) do
    with {:ok, token} <- token(),
         {:ok, ids} <- associated_ids(token, "companies", id, "deals"),
         {:ok, deals} <- batch_read(token, "deals", ids, @deal_props) do
      {:ok, deals |> map_skip(&deal_to_deal/1) |> sort_deals()}
    end
  end

  def do_get_organization_notes(id) do
    with {:ok, token} <- token(),
         {:ok, ids} <- associated_ids(token, "companies", id, "notes"),
         {:ok, notes} <- batch_read(token, "notes", ids, @note_props) do
      {:ok, map_skip(notes, &note_to_note/1)}
    end
  end

  def do_get_organization_activities(id) do
    with {:ok, token} <- token() do
      activities =
        Enum.flat_map(@engagement_types, fn {assoc, label, props} ->
          with {:ok, ids} <- associated_ids(token, "companies", id, assoc),
               {:ok, objs} <- batch_read(token, assoc, ids, props) do
            map_skip(objs, &engagement_to_activity(&1, label))
          else
            _ -> []
          end
        end)

      {:ok, activities}
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP + pagination
  # ---------------------------------------------------------------------------

  defp fetch_companies(_token, _after, acc, page) when page >= @max_pages, do: {:ok, acc}

  defp fetch_companies(token, after_cursor, acc, page) do
    params =
      [limit: @page_size, properties: Enum.join(@company_props, ",")]
      |> maybe_put(:after, after_cursor)

    case get(token, "/crm/v3/objects/companies", params) do
      {:ok, %{"results" => results} = body} ->
        acc = acc ++ map_skip(results, &company_to_org/1)

        case get_in(body, ["paging", "next", "after"]) do
          nil -> {:ok, acc}
          next -> fetch_companies(token, next, acc, page + 1)
        end

      {:ok, _} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # v4 associations: companies -> <to_type>. Returns the list of associated ids.
  defp associated_ids(token, from_type, from_id, to_type) do
    case get(token, "/crm/v4/objects/#{from_type}/#{from_id}/associations/#{to_type}",
           limit: @batch_limit
         ) do
      {:ok, %{"results" => results}} ->
        ids =
          results
          |> Enum.map(fn r -> r["toObjectId"] || r["id"] end)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&to_string/1)
          |> Enum.take(@batch_limit)

        {:ok, ids}

      {:ok, _} ->
        {:ok, []}

      {:error, {:http, 404, _}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp batch_read(_token, _type, [], _props), do: {:ok, []}

  defp batch_read(token, type, ids, props) do
    body = %{
      properties: props,
      inputs: Enum.map(ids, fn id -> %{id: id} end)
    }

    case post(token, "/crm/v3/objects/#{type}/batch/read", body) do
      {:ok, %{"results" => results}} -> {:ok, results}
      {:ok, _} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get(token, path, params) do
    request(:get, path, params: params, headers: auth(token))
  end

  defp post(token, path, body) do
    request(:post, path, json: body, headers: auth(token))
  end

  defp request(method, path, opts) do
    opts = Keyword.merge([url: @base_url <> path, method: method, receive_timeout: 15_000], opts)

    case Req.request(opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Hubspot] #{method} #{path} -> HTTP #{status}")
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth(token), do: [{"authorization", "Bearer #{token}"}]

  # ---------------------------------------------------------------------------
  # Credentials (per-tenant)
  # ---------------------------------------------------------------------------

  defp token do
    case Strings.blank_to_nil(CRM.tenant_settings().hubspot_api_token) do
      nil -> {:error, {:missing_config, :hubspot_api_token}}
      v -> {:ok, v}
    end
  rescue
    # No tenant pinned / settings unavailable.
    _ -> {:error, {:missing_config, :hubspot_api_token}}
  end

  # ---------------------------------------------------------------------------
  # HubSpot -> Pipedrive-shaped mapping. Each mapper returns nil for a record it
  # can't map (missing id / not a map); `map_skip/2` drops those so one odd
  # record never crashes the whole sync.
  # ---------------------------------------------------------------------------

  defp map_skip(list, fun) when is_list(list), do: list |> Enum.map(fun) |> Enum.reject(&is_nil/1)
  defp map_skip(_, _), do: []

  defp company_to_org(%{"id" => id} = obj) when not is_nil(id) do
    props = props_of(obj)
    domain = Strings.blank_to_nil(props["domain"])

    %{
      "id" => to_string(id),
      "name" => props["name"] || "",
      "industry" => Strings.blank_to_nil(props["industry"]),
      # ClientSync infers the real domain from contacts; expose the company's own
      # domain via cc_email as the no-contacts fallback (extract_domain reads it).
      "cc_email" => domain && "noreply@#{domain}"
    }
  end

  defp company_to_org(_), do: nil

  defp contact_to_person(obj) when is_map(obj) do
    props = props_of(obj)

    name =
      [props["firstname"], props["lastname"]] |> Enum.reject(&Strings.blank?/1) |> Enum.join(" ")

    %{
      "name" => name,
      "email" => value_list(props["email"]),
      "phone" => value_list(props["phone"])
    }
  end

  defp contact_to_person(_), do: nil

  defp deal_to_deal(%{"id" => id} = obj) when not is_nil(id) do
    props = props_of(obj)

    %{
      "id" => to_string(id),
      "title" => props["dealname"] || "",
      "value" => parse_amount(props["amount"]),
      "currency" => props["deal_currency_code"] || "",
      "status" => deal_status(props)
    }
  end

  defp deal_to_deal(_), do: nil

  defp note_to_note(obj) when is_map(obj) do
    props = props_of(obj)

    %{
      "content" => strip_html(props["hs_note_body"] || ""),
      "add_time" => to_date_string(props["hs_timestamp"] || props["hs_createdate"])
    }
  end

  defp note_to_note(_), do: nil

  defp engagement_to_activity(obj, label) when is_map(obj) do
    props = props_of(obj)

    subject =
      ~w(hs_call_title hs_email_subject hs_meeting_title hs_call_body hs_meeting_body)
      |> Enum.find_value(fn key -> Strings.blank_to_nil(props[key]) end)

    %{
      "type" => label,
      "subject" => subject || "",
      "due_date" =>
        to_date_string(
          props["hs_timestamp"] || props["hs_meeting_start_time"] || props["hs_createdate"]
        )
    }
  end

  defp engagement_to_activity(_, _), do: nil

  # Translate HubSpot's closed flags into the Pipedrive deal vocabulary the rest
  # of the app branches on ("open"/"won"/"lost"). HubSpot's raw `dealstage` is a
  # pipeline-specific stage ID, not a status, so it can't be compared directly.
  defp deal_status(props) do
    cond do
      truthy(props["hs_is_closed_won"]) -> "won"
      truthy(props["hs_is_closed"]) -> "lost"
      true -> "open"
    end
  end

  defp truthy(v), do: v in [true, "true"]

  # Open/won deals first (mirrors Pipedrive's ordering) so the deal-picking in
  # calendar_sync prefers an active deal.
  defp sort_deals(deals),
    do: Enum.sort_by(deals, &if(&1["status"] in ["open", "won"], do: 0, else: 1))

  defp props_of(obj) when is_map(obj), do: obj["properties"] || %{}
  defp props_of(_), do: %{}

  # Wrap a scalar into Pipedrive's `[%{"value" => v, "primary" => true}]` shape.
  defp value_list(v) when v in [nil, ""], do: []
  defp value_list(v), do: [%{"value" => v, "primary" => true}]

  defp parse_amount(nil), do: nil
  defp parse_amount(n) when is_number(n), do: n

  defp parse_amount(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # HubSpot timestamps are epoch milliseconds (string/int) or ISO8601. Normalize
  # to "YYYY-MM-DD" so ClientSync.parse_date reads it.
  defp to_date_string(nil), do: nil

  defp to_date_string(ts) when is_integer(ts) do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, dt} -> Date.to_iso8601(DateTime.to_date(dt))
      _ -> nil
    end
  end

  defp to_date_string(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {ms, ""} -> to_date_string(ms)
      _ -> ts |> String.split("T") |> hd()
    end
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
