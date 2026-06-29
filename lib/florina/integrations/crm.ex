defmodule Florina.Integrations.CRM do
  @moduledoc """
  Provider-agnostic CRM facade. Picks the active CRM for the current tenant
  (`Settings.crm_provider`: "pipedrive" | "hubspot") and delegates to that
  provider's module. Both provider modules expose the same function surface and
  return the same normalized (Pipedrive-shaped) maps, so callers like
  `Florina.Integrations.ClientSync` don't care which CRM is behind it.

  Each facade call loads the tenant settings once and caches them for the
  duration of that call (process-scoped) so provider-side credential lookups
  reuse them instead of re-querying the singleton row 2-3× per call.
  """

  alias Florina.Integrations.{Hubspot, Pipedrive}

  @cache_key :__crm_settings_cache

  @doc "The provider module for the current tenant (defaults to Pipedrive)."
  def provider_module(settings) do
    case settings.crm_provider do
      "hubspot" -> Hubspot
      _ -> Pipedrive
    end
  end

  @doc """
  The tenant settings to use for the in-flight CRM call. Returns the call-scoped
  cache set by the facade if present, otherwise loads them. Providers call this
  for credentials so a single facade call hits the settings row only once.
  """
  def tenant_settings, do: Process.get(@cache_key) || Florina.Settings.get()

  def list_organizations, do: dispatch(:list_organizations, [])
  def get_organization(id), do: dispatch(:get_organization, [id])
  def get_organization_persons(id), do: dispatch(:get_organization_persons, [id])
  def get_organization_deals(id), do: dispatch(:get_organization_deals, [id])
  def get_organization_notes(id), do: dispatch(:get_organization_notes, [id])
  def get_organization_activities(id), do: dispatch(:get_organization_activities, [id])

  # Resolve settings once, cache them for the provider's credential lookup, pick
  # the provider module, and delegate. Always restores the previous cache value
  # so nested/sequential calls don't leak a stale tenant's settings.
  defp dispatch(fun, args) do
    settings = Florina.Settings.get()
    previous = Process.put(@cache_key, settings)

    try do
      apply(provider_module(settings), fun, args)
    after
      if previous, do: Process.put(@cache_key, previous), else: Process.delete(@cache_key)
    end
  end
end
