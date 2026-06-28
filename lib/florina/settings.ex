defmodule Florina.Settings do
  @moduledoc """
  Context for the per-tenant singleton `GlobalSettings` (`voice_globalsettings`).
  """
  alias Florina.TenantRepo
  alias Florina.Settings.GlobalSettings

  @doc "Get-or-create the singleton settings row for the current tenant."
  def get, do: GlobalSettings.load()

  @doc """
  Update the singleton settings. Returns {:ok, settings} | {:error, changeset}.

  Automatically sets `is_overridden: true` so publish won't overwrite this
  tenant-local edit.
  """
  def update(attrs) do
    GlobalSettings.load()
    |> GlobalSettings.changeset(attrs)
    |> Ecto.Changeset.put_change(:is_overridden, true)
    |> TenantRepo.update()
  end

  @doc """
  Update only this tenant's CRM (Pipedrive) credentials.

  Unlike `update/2`, this does NOT set `is_overridden` — the credentials are
  tenant-private and aren't part of the central config that publishing manages,
  so editing them must not freeze the rest of the settings from central updates.
  An empty/blank value clears the field (so the global env fallback applies).
  """
  def update_crm(attrs) do
    provider = get(attrs, :crm_provider)
    pd_token = blank_to_nil(get(attrs, :pipedrive_api_token))
    pd_domain = blank_to_nil(get(attrs, :pipedrive_domain))
    hs_token = blank_to_nil(get(attrs, :hubspot_api_token))

    # Always set the selected provider and the Pipedrive domain (blank clears it).
    # Only overwrite a token when a new one is supplied — a blank token field keeps
    # the existing secret, so switching provider / editing the domain doesn't wipe
    # the other CRM's saved token.
    changes =
      %{pipedrive_domain: pd_domain}
      |> maybe_put(:crm_provider, blank_to_nil(provider))
      |> maybe_put(:pipedrive_api_token, pd_token)
      |> maybe_put(:hubspot_api_token, hs_token)

    GlobalSettings.load()
    |> GlobalSettings.changeset(changes)
    |> TenantRepo.update()
  end

  defp get(attrs, key), do: attrs[key] || attrs[to_string(key)]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
