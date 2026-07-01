defmodule Florina.Settings do
  @moduledoc """
  Context for the per-tenant singleton `GlobalSettings` (`voice_globalsettings`).
  """
  alias Florina.TenantRepo
  alias Florina.Settings.GlobalSettings
  alias Florina.Strings

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
      |> maybe_clear(attrs, "clear_pipedrive_token", :pipedrive_api_token)
      |> maybe_clear(attrs, "clear_hubspot_token", :hubspot_api_token)

    GlobalSettings.load()
    |> GlobalSettings.changeset(changes)
    |> TenantRepo.update()
  end

  @doc """
  Update only this tenant's outgoing-email (SMTP) credentials. Like `update_crm/1`
  (and unlike `update/1`) it does NOT set `is_overridden` — these are tenant-private
  and not part of the published central config. The password is keep-on-blank (a
  blank field keeps the saved secret); the rest set-when-present (blank clears).
  """
  def update_smtp(attrs) do
    changes =
      %{}
      |> put_present(attrs, :smtp_host, :allow_blank)
      |> put_present(attrs, :smtp_port, :allow_blank)
      |> put_present(attrs, :smtp_username, :allow_blank)
      |> put_present(attrs, :smtp_from, :allow_blank)
      |> put_present(attrs, :smtp_from_name, :allow_blank)
      |> put_present(attrs, :smtp_password, :nonblank)
      |> maybe_clear(attrs, "clear_smtp_password", :smtp_password)

    GlobalSettings.load()
    |> GlobalSettings.changeset(changes)
    |> TenantRepo.update()
  end

  defp put_present(map, attrs, key, mode) do
    if has_key?(attrs, key) do
      case {mode, Strings.blank_to_nil(fetch(attrs, key))} do
        # blank token / provider → keep the existing value
        {:nonblank, nil} -> map
        # allow_blank → set it (nil clears the field)
        {_mode, value} -> Map.put(map, key, value)
      end
    else
      map
    end
  end

  # An explicit "clear" checkbox overrides keep-on-blank, so a stored token can
  # actually be removed (e.g. to revoke a rotated/compromised credential).
  defp maybe_clear(changes, attrs, flag_key, field) do
    if truthy(fetch(attrs, flag_key)), do: Map.put(changes, field, nil), else: changes
  end

  defp truthy(v), do: v in [true, "true", "on"]

  defp has_key?(attrs, key), do: Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key))
  defp fetch(attrs, key), do: attrs[key] || attrs[to_string(key)]
end
