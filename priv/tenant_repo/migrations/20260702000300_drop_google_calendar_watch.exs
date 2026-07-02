defmodule Florina.TenantRepo.Migrations.DropGoogleCalendarWatch do
  use Ecto.Migration

  # Calendar sync is poll-based; the push-based Google calendar-watch code and its
  # table have no callers. Drop the now-unused table.
  def change do
    drop table(:voice_googlecalendarwatch)
  end
end
