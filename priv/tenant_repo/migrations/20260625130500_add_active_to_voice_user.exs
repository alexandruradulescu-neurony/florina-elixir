defmodule Florina.Repo.Migrations.AddActiveToVoiceUser do
  use Ecto.Migration

  def change do
    alter table(:voice_user) do
      add :active, :boolean, null: false, default: true
    end
  end
end
