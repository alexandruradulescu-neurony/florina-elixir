defmodule Florina.Integrations.Hubspot do
  @moduledoc """
  HubSpot CRM API client, exposing the same surface as `Florina.Integrations.Pipedrive`
  so the two are interchangeable behind `Florina.Integrations.CRM`.

  HubSpot's "company" maps to a Pipedrive "organization"; contacts map to persons,
  deals to deals, notes to interaction history. Every `do_*` function translates
  HubSpot's `{id, properties}` shape into the **Pipedrive-shaped** maps that
  `Florina.Integrations.ClientSync` already consumes (string keys; email/phone as
  `[%{"value" => ..., "primary" => true}]`), so the sync orchestration is unchanged.

  Auth: per-tenant **Private App access token** from the tenant settings
  (`Settings.hubspot_api_token`), sent as `Authorization: Bearer <token>`.
  Base URL: `https://api.hubapi.com` (fixed — no per-tenant domain).

  The implementation is chosen via `config :florina, :hubspot_client, …`; tests
  swap in `Florina.Integrations.Hubspot.Stub`.

  NOTE: untested against a live HubSpot account — verify with a real Private App
  token before relying on it in production. Pipedrive is the default provider.
  """

  require Logger

  @base_url "https://api.hubapi.com"
  # Runaway guard for company pagination (50 * 100 = 5000 companies/run).
  @max_pages 50
  @page_size 100
  # HubSpot batch-read accepts at most 100 inputs per request.
  @batch_limit 100

  @company_props ~w(name domain industry)
  @contact_props ~w(firstname lastname email phone)
  @deal_props ~w(dealname amount dealstage deal_currency_code)
  @note_props ~w(hs_note_body hs_timestamp hs_createdate)

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
        {:ok, %{"id" => _} = obj} -> {:ok, company_to_org(obj)}
        {:ok, _} -> {:ok, nil}
        {:error, {:http, 404, _}} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def do_get_organization_persons(id) do
    with {:ok, token} <- token(),
         {:ok, ids} <- associated_ids(token, "companies", id, "contacts"),
         {:ok, contacts} <- batch_read(token, "contacts", ids, @contact_props) do
      {:ok, Enum.map(contacts, &contact_to_person/1)}
    end
  end

  def do_get_organization_deals(id) do
    with {:ok, token} <- token(),
         {:ok, ids} <- associated_ids(token, "companies", id, "deals"),
         {:ok, deals} <- batch_read(token, "deals", ids, @deal_props) do
      {:ok, Enum.map(deals, &deal_to_deal/1)}
    end
  end

  def do_get_organization_notes(id) do
    with {:ok, token} <- token(),
         {:ok, ids} <- associated_ids(token, "companies", id, "notes"),
         {:ok, notes} <- batch_read(token, "notes", ids, @note_props) do
      {:ok, Enum.map(notes, &note_to_note/1)}
    end
  end

  def do_get_organization_activities(_id) do
    # HubSpot engagements (calls/emails/meetings) aren't pulled in v1 — interaction
    # history comes from notes. Return empty so the merge in ClientSync is a no-op.
    {:ok, []}
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
        acc = acc ++ Enum.map(results, &company_to_org/1)

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
    value =
      try do
        Florina.Settings.get().hubspot_api_token
      rescue
        _ -> nil
      end

    case value do
      v when v in [nil, ""] -> {:error, {:missing_config, :hubspot_api_token}}
      v -> {:ok, v}
    end
  end

  # ---------------------------------------------------------------------------
  # HubSpot -> Pipedrive-shaped mapping
  # ---------------------------------------------------------------------------

  defp company_to_org(%{"id" => id} = obj) do
    props = obj["properties"] || %{}
    domain = blank_to_nil(props["domain"])

    %{
      "id" => to_string(id),
      "name" => props["name"] || "",
      "industry" => blank_to_nil(props["industry"]),
      # ClientSync infers the real domain from contacts; expose the company's own
      # domain via cc_email as the no-contacts fallback (extract_domain reads it).
      "cc_email" => domain && "noreply@#{domain}"
    }
  end

  defp contact_to_person(%{"properties" => props}) do
    name = [props["firstname"], props["lastname"]] |> Enum.reject(&blank?/1) |> Enum.join(" ")

    %{
      "name" => name,
      "email" => value_list(props["email"]),
      "phone" => value_list(props["phone"])
    }
  end

  defp deal_to_deal(%{"id" => id, "properties" => props}) do
    %{
      "id" => to_string(id),
      "title" => props["dealname"] || "",
      "value" => parse_amount(props["amount"]),
      "currency" => props["deal_currency_code"] || "",
      "status" => props["dealstage"] || ""
    }
  end

  defp note_to_note(%{"properties" => props}) do
    %{
      "content" => strip_html(props["hs_note_body"] || ""),
      "add_time" => to_date_string(props["hs_timestamp"] || props["hs_createdate"])
    }
  end

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

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  defp blank?(v), do: v in [nil, ""]
end
