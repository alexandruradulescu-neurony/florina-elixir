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

  alias Florina.Clients
  alias Florina.Integrations.Pipedrive, as: PD

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
            {:created, _client} -> %{acc | created: acc.created + 1}
            {:updated, _client} -> %{acc | updated: acc.updated + 1}
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
end
