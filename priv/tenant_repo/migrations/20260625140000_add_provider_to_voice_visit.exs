defmodule Florina.TenantRepo.Migrations.AddProviderToVoiceVisit do
  use Ecto.Migration

  # Records which calendar a synced visit came from (:google | :microsoft) so
  # CalendarSync can match events per-provider. Nullable: existing/manual visits
  # have no provider. Additive column, safe to run on a populated table.
  def change do
    alter table(:voice_visit) do
      add :provider, :string
    end
  end
end
