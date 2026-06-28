defmodule Florina.Integrations.Hubspot.Stub do
  @moduledoc """
  Test stub for `Florina.Integrations.Hubspot`.

  Responses are controlled via the process dictionary, mirroring
  `Florina.Integrations.Pipedrive.Stub`. The dispatch pattern in `Hubspot` calls
  `do_*` on the resolved impl module, so the stub returns the **Pipedrive-shaped**
  maps the real adapter would produce.

  Configured in test.exs:

      config :florina, :hubspot_client, Florina.Integrations.Hubspot.Stub
  """

  def do_list_organizations, do: Process.get(:hs_stub_list_organizations, {:ok, []})
  def do_get_organization(_id), do: Process.get(:hs_stub_get_organization, {:ok, %{}})
  def do_get_organization_deals(_id), do: Process.get(:hs_stub_get_organization_deals, {:ok, []})

  def do_get_organization_persons(_id),
    do: Process.get(:hs_stub_get_organization_persons, {:ok, []})

  def do_get_organization_notes(_id), do: Process.get(:hs_stub_get_organization_notes, {:ok, []})

  def do_get_organization_activities(_id),
    do: Process.get(:hs_stub_get_organization_activities, {:ok, []})

  # ---------------------------------------------------------------------------
  # Helpers for tests
  # ---------------------------------------------------------------------------

  def set_list_organizations(response), do: Process.put(:hs_stub_list_organizations, response)
  def set_get_organization(response), do: Process.put(:hs_stub_get_organization, response)

  def set_get_organization_deals(response),
    do: Process.put(:hs_stub_get_organization_deals, response)

  def set_get_organization_persons(response),
    do: Process.put(:hs_stub_get_organization_persons, response)

  def set_get_organization_notes(response),
    do: Process.put(:hs_stub_get_organization_notes, response)

  def set_get_organization_activities(response),
    do: Process.put(:hs_stub_get_organization_activities, response)

  def reset do
    [
      :hs_stub_list_organizations,
      :hs_stub_get_organization,
      :hs_stub_get_organization_deals,
      :hs_stub_get_organization_persons,
      :hs_stub_get_organization_notes,
      :hs_stub_get_organization_activities
    ]
    |> Enum.each(&Process.delete/1)
  end
end
