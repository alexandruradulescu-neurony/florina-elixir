defmodule Florina.Integrations.ClientSync do
  @moduledoc """
  Syncs client/organization data from Pipedrive into the local `voice_client` table.

  Mirrors Django's `voice/services/client_sync.py` — pure orchestration over:
  - `Florina.Integrations.Pipedrive` behaviour (data source)
  - `Florina.Clients` context (local persistence)

  Fully testable with `Florina.Integrations.Pipedrive.Stub` — no real HTTP needed.

  ## Usage

      Florina.Integrations.ClientSync.sync_all()
      # => {:ok, %{created: 5, updated: 12, errors: []}}

      Florina.Integrations.ClientSync.sync_one("12345")
      # => {:ok, %Florina.Clients.Client{}}
  """

  require Logger

  alias Florina.Clients
  alias Florina.Integrations.Pipedrive, as: PD

  # Maximum number of items stored per enrichment list to avoid DB bloat.
  @max_contacts 20
  @max_deals 20
  @max_interactions 20

  @doc """
  Full sync: pull all organizations from Pipedrive and upsert into the local
  `voice_client` table (per the current tenant in scope on `TenantRepo`).

  Returns `{:ok, %{created: int, updated: int, errors: [String.t()]}}`.
  """
  def sync_all do
    case PD.list_organizations() do
      {:ok, orgs} ->
        results = %{created: 0, updated: 0, errors: []}
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Enum.reduce(orgs, results, fn org, acc ->
          case upsert_client(org, now) do
            {:created, _client} ->
              %{acc | created: acc.created + 1}

            {:updated, _client} ->
              %{acc | updated: acc.updated + 1}

            {:error, reason} ->
              msg = "Error syncing org #{org["id"] || "?"}: #{inspect(reason)}"
              %{acc | errors: [msg | acc.errors]}
          end
        end)
        |> then(fn r -> {:ok, %{r | errors: Enum.reverse(r.errors)}} end)

      {:error, reason} ->
        {:error, {:pipedrive_error, reason}}
    end
  end

  @doc """
  Refresh a single client by its Pipedrive org ID.

  Returns `{:ok, %Florina.Clients.Client{}}` on success, `{:error, reason}` otherwise.
  """
  def sync_one(crm_id) when is_binary(crm_id) do
    case PD.get_organization(crm_id) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, %{} = org} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case upsert_client(org, now) do
          {:created, client} -> {:ok, client}
          {:updated, client} -> {:ok, client}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:pipedrive_error, reason}}
    end
  end

  def sync_one(crm_id), do: sync_one(to_string(crm_id))

  @doc """
  Enriches a local client with CRM data: contacts, deal history, and
  interaction history (notes + activities), then sets `last_synced_at`.

  Each list is bounded to a maximum of `#{@max_interactions}` / `#{@max_deals}` /
  `#{@max_contacts}` entries. Errors from individual Pipedrive calls are
  logged and skipped — they do not abort the enrichment.

  Returns `{:ok, %Florina.Clients.Client{}}` or `{:error, reason}`.
  """
  def enrich_client(%Florina.Clients.Client{crm_id: crm_id} = client)
      when is_binary(crm_id) and crm_id != "" do
    contacts = fetch_contacts(crm_id)
    deal_history = fetch_deal_history(crm_id)
    interaction_history = fetch_interaction_history(crm_id)

    attrs = %{
      contacts: contacts,
      deal_history: deal_history,
      interaction_history: interaction_history,
      last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    Clients.update(client, attrs)
  end

  def enrich_client(%Florina.Clients.Client{} = client) do
    # No crm_id — nothing to enrich, just return the client as-is.
    {:ok, client}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp upsert_client(org, now) when is_map(org) do
    crm_id = to_string(org["id"] || "")

    if crm_id == "" do
      {:error, :missing_id}
    else
      attrs = %{
        crm_id: crm_id,
        name: org["name"] || "",
        domain: extract_domain(org),
        industry: org["industry"] || nil,
        raw_data: org,
        last_synced_at: now
      }

      result =
        case Clients.get_by_crm_id(crm_id) do
          nil ->
            case Clients.create(attrs) do
              {:ok, client} -> {:created, client}
              {:error, changeset} -> {:error, changeset}
            end

          existing ->
            case Clients.update(existing, attrs) do
              {:ok, client} -> {:updated, client}
              {:error, changeset} -> {:error, changeset}
            end
        end

      # Enrich the client regardless of create/update outcome.
      case result do
        {:created, client} ->
          case enrich_client(client) do
            {:ok, enriched} -> {:created, enriched}
            {:error, _reason} -> {:created, client}
          end

        {:updated, client} ->
          case enrich_client(client) do
            {:ok, enriched} -> {:updated, enriched}
            {:error, _reason} -> {:updated, client}
          end

        other ->
          other
      end
    end
  end

  # Fetches and maps organization contacts (persons) from Pipedrive.
  # Returns a bounded list of `%{name, email, phone}` maps.
  defp fetch_contacts(crm_id) do
    case PD.get_organization_persons(crm_id) do
      {:ok, persons} ->
        persons
        |> Enum.take(@max_contacts)
        |> Enum.map(fn p ->
          %{
            name: p["name"] || "",
            email: extract_primary(p["email"]),
            phone: extract_primary(p["phone"])
          }
        end)

      {:error, reason} ->
        Logger.warning("[ClientSync] contacts fetch failed crm_id=#{crm_id}: #{inspect(reason)}")
        []
    end
  end

  # Fetches and maps deal history from Pipedrive.
  # Returns a bounded list of `%{title, value, currency, status}` maps.
  defp fetch_deal_history(crm_id) do
    case PD.get_organization_deals(crm_id) do
      {:ok, deals} ->
        deals
        |> Enum.take(@max_deals)
        |> Enum.map(fn d ->
          %{
            title: d["title"] || "",
            value: d["value"],
            currency: d["currency"] || "",
            status: d["status"] || ""
          }
        end)

      {:error, reason} ->
        Logger.warning(
          "[ClientSync] deal_history fetch failed crm_id=#{crm_id}: #{inspect(reason)}"
        )

        []
    end
  end

  # Fetches notes and activities, merges them into a unified interaction history
  # sorted most-recent first. Returns a bounded list of `%{type, content, date}` maps.
  defp fetch_interaction_history(crm_id) do
    notes = fetch_notes(crm_id)
    activities = fetch_activities(crm_id)

    (notes ++ activities)
    |> Enum.sort_by(& &1.date, {:desc, Date})
    |> Enum.take(@max_interactions)
    |> Enum.map(fn item ->
      %{type: item.type, content: item.content, date: item.date}
    end)
  end

  defp fetch_notes(crm_id) do
    case PD.get_organization_notes(crm_id) do
      {:ok, notes} ->
        Enum.map(notes, fn n ->
          %{
            type: "note",
            content: n["content"] || "",
            date: parse_date(n["add_time"])
          }
        end)

      {:error, reason} ->
        Logger.warning("[ClientSync] notes fetch failed crm_id=#{crm_id}: #{inspect(reason)}")
        []
    end
  end

  defp fetch_activities(crm_id) do
    case PD.get_organization_activities(crm_id) do
      {:ok, activities} ->
        Enum.map(activities, fn a ->
          %{
            type: a["type"] || "activity",
            content: a["subject"] || a["note"] || "",
            date: parse_date(a["due_date"] || a["add_time"])
          }
        end)

      {:error, reason} ->
        Logger.warning(
          "[ClientSync] activities fetch failed crm_id=#{crm_id}: #{inspect(reason)}"
        )

        []
    end
  end

  # Extract a domain from Pipedrive org.
  # Pipedrive stores the cc_email field as "orgname@pipedrivemail.com" for auto-generated
  # forwarding addresses, but the real domain is sometimes in "owner_name" or custom fields.
  # As a best-effort, we split the cc_email domain part — matching Django's `_normalize_client`.
  defp extract_domain(%{"cc_email" => cc_email}) when is_binary(cc_email) and cc_email != "" do
    case String.split(cc_email, "@") do
      [_, domain] when domain != "" -> domain
      _ -> nil
    end
  end

  defp extract_domain(_), do: nil

  # Pipedrive returns email/phone as a list of `%{"value" => ..., "primary" => true/false}`.
  # Extract the primary entry's value, falling back to the first entry.
  defp extract_primary(nil), do: nil
  defp extract_primary([]), do: nil

  defp extract_primary(list) when is_list(list) do
    primary = Enum.find(list, fn item -> item["primary"] == true end) || hd(list)
    primary["value"]
  end

  defp extract_primary(value) when is_binary(value), do: value

  # Parse a Pipedrive date string ("YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS") into a `Date`.
  defp parse_date(nil), do: Date.utc_today()

  defp parse_date(str) when is_binary(str) do
    date_part = str |> String.split(" ") |> hd()

    case Date.from_iso8601(date_part) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  defp parse_date(_), do: Date.utc_today()
end
