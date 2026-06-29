defmodule Florina.Repo.Migrations.DropVoiceVoiceprompt do
  use Ecto.Migration

  # The Voice Prompts feature was removed on 2026-06-27 (the Auto Prompt Assembler
  # composes each meeting's script from the Mega Prompt + Claude directly onto the
  # Visit; `voice_voiceprompt` was never read by the call/assembly path). The
  # control-plane table is dead — drop it. `down` recreates it for reversibility.
  def up do
    drop table(:voice_voiceprompt)
  end

  def down do
    create table(:voice_voiceprompt) do
      add :name, :string, size: 100, null: false
      add :system_prompt, :text, null: false
      add :first_message, :text
      add :prompt_type, :string, size: 20, null: false, default: "PRE"
      add :is_active, :boolean, null: false, default: true

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_voiceprompt, [:prompt_type],
             where: "is_active",
             name: "unique_active_prompt"
           )
  end
end
