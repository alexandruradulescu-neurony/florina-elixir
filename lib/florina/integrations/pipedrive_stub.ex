defmodule Florina.Integrations.Pipedrive.Stub do
  @moduledoc """
  Test stub for `Florina.Integrations.Pipedrive`.

  Responses are controlled via the process dictionary.

  Usage:

      alias Florina.Integrations.Pipedrive.Stub, as: PD

      PD.set_list_organizations({:ok, [
        %{"id" => 1, "name" => "Acme Corp", "cc_email" => "acme@acme.com"}
      ]})

  Default (no setup): returns empty lists / default maps so tests that don't
  care about the exact output still pass.

  Configured in test.exs:

      config :florina, :pipedrive_client, Florina.Integrations.Pipedrive.Stub
  """

  # The dispatch pattern in Pipedrive calls do_* on the resolved impl module.

  def do_list_organizations do
    Process.get(:pd_stub_list_organizations, {:ok, []})
  end

  def do_get_organization(_id) do
    Process.get(:pd_stub_get_organization, {:ok, %{}})
  end

  def do_search_organizations(_term) do
    Process.get(:pd_stub_search_organizations, {:ok, []})
  end

  def do_get_organization_deals(_org_id) do
    Process.get(:pd_stub_get_organization_deals, {:ok, []})
  end

  def do_get_deal(_deal_id) do
    Process.get(:pd_stub_get_deal, {:ok, %{}})
  end

  def do_get_organization_persons(_org_id) do
    Process.get(:pd_stub_get_organization_persons, {:ok, []})
  end

  def do_get_organization_notes(_org_id) do
    Process.get(:pd_stub_get_organization_notes, {:ok, []})
  end

  def do_get_organization_activities(_org_id) do
    Process.get(:pd_stub_get_organization_activities, {:ok, []})
  end

  def do_create_note(_deal_id, _text, _subject) do
    Process.get(:pd_stub_create_note, {:ok, %{"id" => 99, "content" => "stub note"}})
  end

  # ---------------------------------------------------------------------------
  # Helpers for tests
  # ---------------------------------------------------------------------------

  def set_list_organizations(response), do: Process.put(:pd_stub_list_organizations, response)
  def set_get_organization(response), do: Process.put(:pd_stub_get_organization, response)
  def set_search_organizations(response), do: Process.put(:pd_stub_search_organizations, response)
  def set_get_organization_deals(response), do: Process.put(:pd_stub_get_organization_deals, response)
  def set_get_deal(response), do: Process.put(:pd_stub_get_deal, response)
  def set_get_organization_persons(response), do: Process.put(:pd_stub_get_organization_persons, response)
  def set_get_organization_notes(response), do: Process.put(:pd_stub_get_organization_notes, response)
  def set_get_organization_activities(response), do: Process.put(:pd_stub_get_organization_activities, response)
  def set_create_note(response), do: Process.put(:pd_stub_create_note, response)

  def reset do
    [:pd_stub_list_organizations, :pd_stub_get_organization, :pd_stub_search_organizations,
     :pd_stub_get_organization_deals, :pd_stub_get_deal, :pd_stub_get_organization_persons,
     :pd_stub_get_organization_notes, :pd_stub_get_organization_activities, :pd_stub_create_note]
    |> Enum.each(&Process.delete/1)
  end
end
