defmodule Florina.Integrations.CRM do
  @moduledoc """
  Provider-agnostic CRM facade. Picks the active CRM for the current tenant
  (`Settings.crm_provider`: "pipedrive" | "hubspot") and delegates to that
  provider's module. Both provider modules expose the same function surface and
  return the same normalized (Pipedrive-shaped) maps, so callers like
  `Florina.Integrations.ClientSync` don't care which CRM is behind it.

  Each provider module keeps its own test-stub indirection (`impl/0`), so this
  facade only selects the provider family, not the stub.
  """

  alias Florina.Integrations.{Hubspot, Pipedrive}

  @doc "The provider module for the current tenant (defaults to Pipedrive)."
  def provider_module do
    case current_provider() do
      "hubspot" -> Hubspot
      _ -> Pipedrive
    end
  end

  @doc "The active CRM provider for the current tenant (\"pipedrive\" | \"hubspot\")."
  def current_provider do
    Florina.Settings.get().crm_provider || "pipedrive"
  rescue
    # No tenant pinned / settings unavailable — fall back to the default so a
    # missing context never crashes a caller; the underlying query will still
    # fail-closed if a CRM call is actually attempted without a tenant.
    _ -> "pipedrive"
  end

  def list_organizations, do: provider_module().list_organizations()
  def get_organization(id), do: provider_module().get_organization(id)
  def get_organization_persons(id), do: provider_module().get_organization_persons(id)
  def get_organization_deals(id), do: provider_module().get_organization_deals(id)
  def get_organization_notes(id), do: provider_module().get_organization_notes(id)
  def get_organization_activities(id), do: provider_module().get_organization_activities(id)
end
