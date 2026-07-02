defmodule Florina.Integrations.ClientSync do
  @moduledoc """
  Syncs client/organization data from the tenant's CRM into the local
  `voice_client` table.

  Mirrors Django's `voice/services/client_sync.py` — pure orchestration over:
  - `Florina.Integrations.CRM` facade (data source — Pipedrive or HubSpot per
    the tenant's `crm_provider` setting)
  - `Florina.Clients` context (local persistence)

  Fully testable with the provider stubs — no real HTTP needed.

  ## Usage

      Florina.Integrations.ClientSync.sync_all()
      # => {:ok, %{created: 5, updated: 12, errors: []}}

      Florina.Integrations.ClientSync.sync_one("12345")
      # => {:ok, %Florina.Clients.Client{}}
  """

  require Logger

  alias Florina.Clients
  alias Florina.Integrations.CRM

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
    case CRM.list_organizations() do
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
        {:error, {:crm_error, reason}}
    end
  end

  @doc """
  Refresh a single client by its Pipedrive org ID.

  Returns `{:ok, %Florina.Clients.Client{}}` on success, `{:error, reason}` otherwise.
  """
  def sync_one(crm_id) when is_binary(crm_id) do
    case CRM.get_organization(crm_id) do
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
        {:error, {:crm_error, reason}}
    end
  end

  def sync_one(crm_id), do: sync_one(to_string(crm_id))

  @doc """
  Enriches a local client with CRM data: contacts, deal history, and
  interaction history (notes + activities), then sets `last_synced_at`.

  **Merge, never overwrite.** Freshly-fetched CRM data is unioned into what's
  already stored: a fresh entry wins over the matching stored one, but any stored
  entry the CRM no longer returns is KEPT. And if a fetch ERRORS (timeout / rate
  limit / auth), that field is left completely untouched. So a transient or
  partial CRM failure can never wipe a client's contacts/deals/history — the data
  only ever accumulates or is refreshed, never lost. Each list is bounded to
  `#{@max_contacts}`/`#{@max_deals}`/`#{@max_interactions}` entries (fresh first).

  Returns `{:ok, %Florina.Clients.Client{}}` or `{:error, reason}`.
  """
  def enrich_client(%Florina.Clients.Client{crm_id: crm_id} = client)
      when is_binary(crm_id) and crm_id != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    contacts_result = fetch_contacts(crm_id)

    attrs =
      %{last_synced_at: now}
      |> merge_list(:contacts, client.contacts, contacts_result, &contact_key/1, @max_contacts)
      |> merge_list(
        :deal_history,
        client.deal_history,
        fetch_deal_history(crm_id),
        &deal_key/1,
        @max_deals
      )
      |> merge_interactions(client.interaction_history, fetch_interaction_history(crm_id))
      |> maybe_put_domain(domain_from_result(contacts_result))

    Clients.update(client, attrs)
  end

  def enrich_client(%Florina.Clients.Client{} = client) do
    # No crm_id — nothing to enrich, just return the client as-is.
    {:ok, client}
  end

  # --- Merge helpers (never lose stored data on a failed/partial fetch) -------

  # {:ok, fetched} → union fresh with stored, cap. {:error, _} → leave stored as-is.
  defp merge_list(attrs, key, existing, {:ok, fetched}, keyfn, cap) do
    merged = existing |> List.wrap() |> union_by(fetched, keyfn) |> Enum.take(cap)
    Map.put(attrs, key, merged)
  end

  defp merge_list(attrs, _key, _existing, {:error, _reason}, _keyfn, _cap), do: attrs

  defp merge_interactions(attrs, existing, {:ok, fetched}) do
    merged =
      existing
      |> List.wrap()
      |> union_by(fetched, &interaction_key/1)
      |> Enum.sort_by(&Map.get(&1, "date", ""), :desc)
      |> Enum.take(@max_interactions)

    Map.put(attrs, :interaction_history, merged)
  end

  defp merge_interactions(attrs, _existing, {:error, _reason}), do: attrs

  # Fresh entries first (they win the cap and refresh matching stored ones), then
  # stored entries the CRM didn't return this time (kept — never dropped).
  defp union_by(existing, fetched, keyfn) do
    fetched_keys = MapSet.new(fetched, keyfn)
    kept = Enum.reject(existing, fn m -> MapSet.member?(fetched_keys, keyfn.(m)) end)
    fetched ++ kept
  end

  # Stored maps are string-keyed (JSON round-trip); fetched maps are built
  # string-keyed too, so identity keys read string keys throughout.
  defp contact_key(m), do: {m["email"] || "", m["name"] || ""}
  defp deal_key(m), do: m["id"] || {m["title"], m["value"], m["status"]}
  defp interaction_key(m), do: {m["type"], m["content"], m["date"]}

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

  # Fetch org contacts (persons). `{:ok, [%{"name","email","phone"}]}` (string-keyed
  # to match the stored/merged shape) or `{:error, reason}` on a failed CRM call.
  defp fetch_contacts(crm_id) do
    case CRM.get_organization_persons(crm_id) do
      {:ok, persons} ->
        {:ok,
         Enum.map(persons, fn p ->
           %{
             "name" => p["name"] || "",
             "email" => extract_primary(p["email"]),
             "phone" => extract_primary(p["phone"])
           }
         end)}

      {:error, reason} ->
        Logger.warning("[ClientSync] contacts fetch failed crm_id=#{crm_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Fetch deal history. `{:ok, [%{"id","title","value","currency","status"}]}` or
  # `{:error, reason}`. `id` gives a stable identity so a status change refreshes
  # the same deal instead of duplicating it.
  defp fetch_deal_history(crm_id) do
    case CRM.get_organization_deals(crm_id) do
      {:ok, deals} ->
        {:ok,
         Enum.map(deals, fn d ->
           %{
             "id" => d["id"] && to_string(d["id"]),
             "title" => d["title"] || "",
             "value" => d["value"],
             "currency" => d["currency"] || "",
             "status" => d["status"] || ""
           }
         end)}

      {:error, reason} ->
        Logger.warning(
          "[ClientSync] deal_history fetch failed crm_id=#{crm_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Combine notes + activities. `{:ok, list}` if at least one call succeeded (a
  # partial result still only adds via the union); `{:error, reason}` only when
  # BOTH failed, so the stored history is left untouched.
  defp fetch_interaction_history(crm_id) do
    notes = fetch_notes(crm_id)
    activities = fetch_activities(crm_id)

    case {notes, activities} do
      {{:error, reason}, {:error, _}} -> {:error, reason}
      _ -> {:ok, ok_list(notes) ++ ok_list(activities)}
    end
  end

  defp ok_list({:ok, list}), do: list
  defp ok_list(_), do: []

  defp fetch_notes(crm_id) do
    case CRM.get_organization_notes(crm_id) do
      {:ok, notes} ->
        {:ok,
         Enum.map(notes, fn n ->
           %{
             "type" => "note",
             "content" => n["content"] || "",
             "date" => iso(parse_date(n["add_time"]))
           }
         end)}

      {:error, reason} ->
        Logger.warning("[ClientSync] notes fetch failed crm_id=#{crm_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_activities(crm_id) do
    case CRM.get_organization_activities(crm_id) do
      {:ok, activities} ->
        {:ok,
         Enum.map(activities, fn a ->
           %{
             "type" => a["type"] || "activity",
             "content" => a["subject"] || a["note"] || "",
             "date" => iso(parse_date(a["due_date"] || a["add_time"]))
           }
         end)}

      {:error, reason} ->
        Logger.warning(
          "[ClientSync] activities fetch failed crm_id=#{crm_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp iso(%Date{} = d), do: Date.to_iso8601(d)
  defp iso(_), do: ""

  # Fallback domain from the Pipedrive org's `cc_email`. Pipedrive's cc_email is
  # an auto-generated forwarding address whose domain is "<account>.pipedrivemail.com"
  # — NOT the client's real domain — so that is rejected here. The real domain is
  # inferred from the org's contacts (see `domain_from_contacts/1` in enrich_client);
  # a non-pipedrive cc_email is only used as a fallback when there are no contacts.
  defp extract_domain(%{"cc_email" => cc_email}) when is_binary(cc_email) and cc_email != "" do
    case String.split(cc_email, "@") do
      [_, domain] when domain != "" -> usable_domain(String.downcase(domain))
      _ -> nil
    end
  end

  defp extract_domain(_), do: nil

  # Domain is only inferred when the contacts fetch succeeded (never on error, so
  # we don't clobber a stored domain because the CRM was briefly unreachable).
  defp domain_from_result({:ok, contacts}), do: domain_from_contacts(contacts)
  defp domain_from_result({:error, _reason}), do: nil

  # Prefer the real company domain inferred from the org's contacts' email
  # addresses: the most common domain that isn't a free provider or pipedrivemail.
  defp domain_from_contacts(contacts) do
    contacts
    |> Enum.map(& &1["email"])
    |> Enum.map(&email_domain/1)
    |> Enum.map(&usable_domain/1)
    |> Enum.reject(&is_nil/1)
    |> most_common()
  end

  defp email_domain(email) when is_binary(email) do
    case String.split(email, "@") do
      [_, d] when d != "" -> String.downcase(d)
      _ -> nil
    end
  end

  defp email_domain(_), do: nil

  @free_email_domains ~w(gmail.com googlemail.com yahoo.com hotmail.com outlook.com live.com icloud.com aol.com proton.me protonmail.com)

  # Returns the domain unless it's a free provider or a pipedrivemail forwarding
  # domain (neither identifies the client company), in which case nil.
  defp usable_domain(nil), do: nil

  defp usable_domain(domain) do
    if domain in @free_email_domains or String.contains?(domain, "pipedrivemail.com"),
      do: nil,
      else: domain
  end

  defp most_common([]), do: nil

  defp most_common(domains) do
    domains
    |> Enum.frequencies()
    |> Enum.max_by(fn {_domain, count} -> count end)
    |> elem(0)
  end

  defp maybe_put_domain(attrs, nil), do: attrs
  defp maybe_put_domain(attrs, domain), do: Map.put(attrs, :domain, domain)

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
