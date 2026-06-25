defmodule Florina.TenantRepo.Migrations.BackfillVisitProvider do
  @moduledoc """
  Tags pre-existing calendar-synced visits with provider `:google`.

  Before multi-provider support the only calendar stack was Google, so any visit
  that has a `calendar_event_id` but no `provider` came from Google. Without this
  backfill the now provider-aware `CalendarSync.find_existing_visit/3` wouldn't
  match those rows and would create duplicate visits on the next sync. Touches 0
  rows in environments that have no synced visits yet (all of them, in practice)
  — purely defensive / forward-safe.
  """
  use Ecto.Migration

  def up do
    execute(
      "UPDATE voice_visit SET provider = 'google' " <>
        "WHERE calendar_event_id IS NOT NULL AND provider IS NULL"
    )
  end

  def down, do: :ok
end
