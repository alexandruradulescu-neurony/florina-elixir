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

  Auth: global API token from `config :florina, :pipedrive_api_token`.
  Base URL: `https://{PIPEDRIVE_DOMAIN}.pipedrive.com/api/v1`.

  Deferred:
  - `search_deals/1` (search by term) — not used in core sync/CRM push path;
    can be added when the deal-matching UI feature is built.
  - `update_deal/2`, `create_deal/1` — write-side deal ops not needed yet.
  """

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
             params: [term: term, fields: "name", api_token: token],
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
          sorted =
            Enum.sort_by(deals, fn d ->
              status_rank = if d["status"] in ["open", "won"], do: 0, else: 1
              {status_rank, -(d["update_time"] || 0)}
            end)

          {:ok, sorted}

        {:ok, _other} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
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
             params: [api_token: token],
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
    domain = Application.get_env(:florina, :pipedrive_domain, "")

    if domain in [nil, ""] do
      {:error, {:missing_config, :pipedrive_domain}}
    else
      {:ok, "https://#{domain}.pipedrive.com/api/v1"}
    end
  end

  defp api_token do
    token = Application.get_env(:florina, :pipedrive_api_token, "")

    if token in [nil, ""] do
      {:error, {:missing_config, :pipedrive_api_token}}
    else
      {:ok, token}
    end
  end

  # Simple GET that auto-unwraps Pipedrive's `{success: true, data: ...}` envelope.
  defp pipedrive_get(url, token) do
    case Req.get(url, params: [api_token: token], receive_timeout: 15_000) do
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
  defp fetch_all_pages(url, token) do
    fetch_page(url, token, 0, 100, [])
  end

  defp fetch_page(url, token, start, limit, acc) do
    case Req.get(url,
           params: [api_token: token, start: start, limit: limit],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        if body["success"] do
          items = body["data"] || []
          all = acc ++ items
          more = get_in(body, ["additional_data", "pagination", "more_items_in_collection"]) || false

          if more do
            fetch_page(url, token, start + limit, limit, all)
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
