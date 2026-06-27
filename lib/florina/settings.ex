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
end
