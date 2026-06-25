defmodule Florina.TenantRepo.Migrations.CreateConfigOverrides do
  @moduledoc """
  Adds `is_overridden` flag to all five config tables in TENANT databases.

  When `is_overridden = true`, the `publish` operation will skip that row,
  preserving the tenant's custom value. The flag is false by default so all
  rows created by `seed_tenant` start as "follows central config".
  """
  use Ecto.Migration

  def change do
    alter table(:voice_methodology) do
      add :is_overridden, :boolean, null: false, default: false
    end

    alter table(:voice_scenario) do
      add :is_overridden, :boolean, null: false, default: false
    end

    alter table(:voice_voiceprompt) do
      add :is_overridden, :boolean, null: false, default: false
    end

    alter table(:voice_megaprompt) do
      add :is_overridden, :boolean, null: false, default: false
    end

    alter table(:voice_globalsettings) do
      add :is_overridden, :boolean, null: false, default: false
    end
  end
end
