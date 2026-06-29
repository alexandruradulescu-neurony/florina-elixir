defmodule Florina.Integrations.Pipedrive do
  @moduledoc """
  Pipedrive CRM API v1 client.

  Behaviour callbacks (all the operations used by sync + post-call CRM push):
  - `list_organizations/0` — paginated pull of all orgs (for client sync).
  - `get_organization/1` — fetch a single org by ID.
  - `search_organizations/1` — search orgs by term (used to match by domain).
  - `get_organization_deals/1` — list deals for an org.
  - `get_deal/1` — fetch a single deal by ID.
  - `get_organization_persons/1` — list contacts for an org.
  - `get_organization_notes/1` — fetch notes for an org (interaction history).
  - `get_organization_activities/1` — fetch activities for an org.
  - `create_note/3` — create a note on a deal.

  The implementation is chosen via:

      config :florina, :pipedrive_client, Florina.Integrations.Pipedrive

  Tests swap in `Florina.Integrations.Pipedrive.Stub`.

  Auth: per-tenant API token from the tenant's settings
  (`Settings.pipedrive_api_token`) — no global fallback.
  Base URL: `https://{tenant pipedrive_domain}.pipedrive.com/api/v1`.

  Deferred:
  - `search_deals/1` (search by term) — not used in core sync/CRM push path;
    can be added when the deal-matching UI feature is built.
  - `update_deal/2`, `create_deal/1` — write-side deal ops not needed yet.
  """

  require Logger

  alias Florina.Strings

  # Runaway guard for organization pagination (50 * 100 = 5000 orgs/run).
  @max_pages 50

  @callback list_organizations() :: {:ok, [map()]} | {:error, term()}
  @callback get_organization(String.t() | integer()) :: {:ok, map()} | {:error, term()}
  @callback search_organizations(String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_organization_deals(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback get_deal(String.t() | integer()) :: {:ok, map()} | {:error, term()}
  @callback get_organization_persons(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback get_organization_notes(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback get_organization_activities(String.t() | integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback create_note(String.t() | integer(), String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Resolve the configured implementation
  # ---------------------------------------------------------------------------

  @doc false
  def impl do
    Application.get_env(:florina, :pipedrive_client, __MODULE__)
  end

  @doc "Pull all organizations (paginated, returns normalized list)."
  def list_organizations, do: impl().do_list_organizations()

  @doc "Fetch a single org by Pipedrive ID."
  def get_organization(id), do: impl().do_get_organization(id)

  @doc "Search organizations by term (fuzzy name match)."
  def search_organizations(term), do: impl().do_search_organizations(term)

  @doc "List all deals for an organization."
  def get_organization_deals(org_id), do: impl().do_get_organization_deals(org_id)

  @doc "Fetch a single deal by ID."
  def get_deal(deal_id), do: impl().do_get_deal(deal_id)

  @doc "List contact persons for an organization."
  def get_organization_persons(org_id), do: impl().do_get_organization_persons(org_id)

  @doc "Fetch notes (interaction history) for an organization."
  def get_organization_notes(org_id), do: impl().do_get_organization_notes(org_id)

  @doc "Fetch activities for an organization."
  def get_organization_activities(org_id), do: impl().do_get_organization_activities(org_id)

  @doc """
  Create a note on a deal.

  - `deal_id`: Pipedrive deal ID.
  - `text`: Note content (markdown supported).
  - `subject`: Optional subject line.
  """
  def create_note(deal_id, text, subject \\ ""),
    do: impl().do_create_note(deal_id, text, subject)

  # ---------------------------------------------------------------------------
  # Real implementation (do_* names avoid collision with delegating API above).
  # ---------------------------------------------------------------------------

  @doc false
  def do_list_organizations do
    with {:ok, base_url} <- base_url(),
         {:ok, token} <- api_token() do
      fetch_all_pages("#{base_url}/organizations", token)
    end
  end

  @doc false
  def do_get_organization(id) do
    with {:ok, base_url} <- base_url(),
         {:ok, token} <- api_token() do
      case pipedrive_get("#{base_url}/organizations/#{id}", token) do
        {:ok, data} -> {:ok, data}
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def do_search_organizations(term) when is_binary(term) and term != "" do
    with {:ok, base_url} <- base_url(),
         {:ok, token} <- api_token() do
      case Req.get("#{base_url}/organizations/search",
             headers: auth_headers(token),
             params: [term: term, fields: "name"],
             receive_timeout: 15_000
           ) do
        {:ok, %{status: 200, body: body}} ->
          items = get_in(body, ["data", "items"]) || []
          orgs = Enum.map(items, & &1["item"])
          {:ok, orgs}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def do_search_organizations(_), do: {:ok, []}

  @doc false
  def do_get_organization_deals(org_id) do
    with {:ok, base_url} <- base_url(),
         {:ok, token} <- api_token() do
      case pipedrive_get("#{base_url}/organizations/#{org_id}/deals", token) do
        {:ok, deals} when is_list(deals) ->
          {:ok, sort_deals(deals)}

        {:ok, _other} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  # Sort by recency (desc) first, then stable-sort open/won deals ahead of the
  # rest. Pipedrive returns `update_time` as a string ("YYYY-MM-DD HH:MM:SS"),
  # which sorts chronologically as text; the old `-(update_time)` negated a
  # string and crashed with ArithmeticError. Enum.sort_by is stable, so the
  # recency order is preserved within each status group. Deals with no
  # update_time sort last.
  def sort_deals(deals) when is_list(deals) do
    deals
    |> Enum.sort_by(&(&1["update_time"] || ""), :desc)
    |> Enum.sort_by(&if(&1["status"] in ["open", "won"], do: 0, else: 1))
  end

  @doc false
  def do_get_deal(deal_id) do
    with {:ok, base_url} <- base_url(),
         {:ok, token} <- api_token() do
      pipedrive_get("#{base_url}/deals/#{deal_id}", token)
    end
  end

  @doc false
  def do_get_organization_persons(org_id) do
    with {:ok, base_url} <- base_url(),
         {:ok, token} <- api_token() do
      case pipedrive_get("#{base_url}/organizations/#{org_id}/persons", token) do
        {:ok, persons} when is_list(persons) -> {:ok, persons}
        {:ok, _other} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def do_get_organization_notes(org_id) do
    with {:ok, base_url} <- base_url(),
         {:ok, token} <- api_token() do
      case pipedrive_get("#{base_url}/organizations/#{org_id}/notes", token) do
        {:ok, notes} when is_list(notes) -> {:ok, notes}
        {:ok, _other} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def do_get_organization_activities(org_id) do
    with {:ok, base_url} <- base_url(),
         {:ok, token} <- api_token() do
      case pipedrive_get("#{base_url}/organizations/#{org_id}/activities", token) do
        {:ok, acts} when is_list(acts) -> {:ok, acts}
        {:ok, _other} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def do_create_note(deal_id, text, subject) do
    with {:ok, base_url} <- base_url(),
         {:ok, token} <- api_token() do
      body =
        %{"content" => text, "deal_id" => deal_id, "pinned_to_deal_flag" => 1}
        |> then(fn b ->
          if subject != "", do: Map.put(b, "subject", subject), else: b
        end)

      case Req.post("#{base_url}/notes",
             headers: auth_headers(token),
             json: body,
             receive_timeout: 15_000
           ) do
        {:ok, %{status: status, body: resp}} when status in [200, 201] ->
          if resp["success"] do
            {:ok, resp["data"] || %{}}
          else
            {:error, {:pipedrive_error, resp}}
          end

        {:ok, %{status: status, body: resp}} ->
          {:error, {:http, status, resp}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp base_url do
    domain = tenant_creds().domain

    if domain in [nil, ""] do
      {:error, {:missing_config, :pipedrive_domain}}
    else
      {:ok, "https://#{domain}.pipedrive.com/api/v1"}
    end
  end

  defp api_token do
    token = tenant_creds().token

    if token in [nil, ""] do
      {:error, {:missing_config, :pipedrive_api_token}}
    else
      {:ok, token}
    end
  end

  # Each Pipedrive call runs in a tenant-pinned context (the sync/calendar
  # workers pin the tenant first), so credentials come strictly from that
  # tenant's own settings — there is NO global fallback, so a tenant with no
  # creds imports nothing (rather than leaking another tenant's CRM). Settings
  # come from the CRM facade's call-scoped cache so a single sync call doesn't
  # re-query the row.
  defp tenant_creds do
    settings =
      try do
        Florina.Integrations.CRM.tenant_settings()
      rescue
        _ -> nil
      end

    %{
      token: settings && Strings.blank_to_nil(settings.pipedrive_api_token),
      domain: settings && Strings.blank_to_nil(settings.pipedrive_domain)
    }
  end

  # Pipedrive accepts the API token via the `x-api-token` header (documented
  # alternative to the `?api_token=` query param) — keeps the secret out of URLs,
  # access logs, and request traces.
  defp auth_headers(token), do: [{"x-api-token", token}]

  # Simple GET that auto-unwraps Pipedrive's `{success: true, data: ...}` envelope.
  defp pipedrive_get(url, token) do
    case Req.get(url, headers: auth_headers(token), receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"success" => true, "data" => data}}} ->
        {:ok, data}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 200, body: %{"success" => false} = body}} ->
        {:error, {:pipedrive_error, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Paginated fetch for /organizations (and any list endpoint that uses start/limit).
  # Capped at @max_pages as a runaway guard; the cap is logged, never silent.
  defp fetch_all_pages(url, token) do
    fetch_page(url, token, 0, 100, [], 0)
  end

  defp fetch_page(_url, _token, _start, _limit, acc, page) when page >= @max_pages do
    Logger.warning(
      "[Pipedrive] organization pagination hit the #{@max_pages}-page cap " <>
        "(#{length(acc)} fetched) — remaining orgs skipped this run"
    )

    {:ok, acc}
  end

  defp fetch_page(url, token, start, limit, acc, page) do
    case Req.get(url,
           headers: auth_headers(token),
           params: [start: start, limit: limit],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        if body["success"] do
          items = body["data"] || []
          all = acc ++ items

          more =
            get_in(body, ["additional_data", "pagination", "more_items_in_collection"]) || false

          if more do
            fetch_page(url, token, start + limit, limit, all, page + 1)
          else
            {:ok, all}
          end
        else
          {:ok, acc}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
