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
    # Only touch fields that were actually submitted, so a form that hides one
    # provider's fields (conditional UI) doesn't wipe that provider's saved creds.
    # Tokens are keep-on-blank (a blank field keeps the existing secret); the
    # Pipedrive domain is set when present (a present-but-blank value clears it).
    changes =
      %{}
      |> put_present(attrs, :crm_provider, :nonblank)
      |> put_present(attrs, :pipedrive_domain, :allow_blank)
      |> put_present(attrs, :pipedrive_api_token, :nonblank)
      |> put_present(attrs, :hubspot_api_token, :nonblank)

    GlobalSettings.load()
    |> GlobalSettings.changeset(changes)
    |> TenantRepo.update()
  end

  defp put_present(map, attrs, key, mode) do
    if has_key?(attrs, key) do
      case {mode, blank_to_nil(fetch(attrs, key))} do
        # blank token / provider → keep the existing value
        {:nonblank, nil} -> map
        # allow_blank → set it (nil clears the field)
        {_mode, value} -> Map.put(map, key, value)
      end
    else
      map
    end
  end

  defp has_key?(attrs, key), do: Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key))
  defp fetch(attrs, key), do: attrs[key] || attrs[to_string(key)]

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
