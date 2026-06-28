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
    token = blank_to_nil(attrs[:pipedrive_api_token] || attrs["pipedrive_api_token"])
    domain = blank_to_nil(attrs[:pipedrive_domain] || attrs["pipedrive_domain"])

    # Always set the domain (blank clears it). Only overwrite the token when a new
    # one is supplied — a blank token field keeps the existing secret, so editing
    # the domain alone doesn't wipe the token.
    changes = %{pipedrive_domain: domain}
    changes = if token, do: Map.put(changes, :pipedrive_api_token, token), else: changes

    GlobalSettings.load()
    |> GlobalSettings.changeset(changes)
    |> TenantRepo.update()
  end

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
