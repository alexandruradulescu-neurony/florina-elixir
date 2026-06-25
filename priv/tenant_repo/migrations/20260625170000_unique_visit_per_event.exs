defmodule Florina.TenantRepo.Migrations.UniqueVisitPerEvent do
  use Ecto.Migration

  # Backstop visit idempotency: a calendar event maps to at most one visit per
  # (agent, provider). Partial unique index so manually-created visits (which
  # have no calendar_event_id) stay unconstrained. Replaces sole reliance on the
  # read-then-insert check in CalendarSync, which two overlapping sync jobs could
  # both pass and create duplicate visits.
  def change do
    create unique_index(:voice_visit, [:agent_id, :provider, :calendar_event_id],
             where: "calendar_event_id IS NOT NULL",
             name: :voice_visit_agent_provider_event_uidx
           )
  end
end
