defmodule Florina.Repo.Migrations.CreateCentralConfig do
  @moduledoc """
  Creates the five canonical config tables in the CONTROL-PLANE database.

  These tables are the single source of truth for shared configuration.
  They mirror the per-tenant schema (create_backend_schema) with two changes:

  1. `created_by_id` columns are plain :bigint (nullable) — no FK because
     voice_user lives only in per-tenant databases, not in the control plane.
  2. `voice_globalsettings.default_methodology_id` KEEPS its FK because
     both voice_methodology and voice_globalsettings are in the control plane.
  """
  use Ecto.Migration

  def change do
    # -------------------------------------------------------------------------
    # 1. voice_methodology
    #    (created_by_id is a plain bigint — no FK to voice_user)
    # -------------------------------------------------------------------------
    create table(:voice_methodology) do
      add :name, :string, size: 255, null: false
      add :description, :text
      add :source_material, :string, size: 255
      add :ai_summary, :text
      add :is_active, :boolean, null: false, default: true
      # Plain bigint, no references — voice_user is per-tenant only
      add :created_by_id, :bigint, null: true

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_methodology, [:is_active])
    create index(:voice_methodology, [:created_by_id])

    # -------------------------------------------------------------------------
    # 2. voice_scenario
    # -------------------------------------------------------------------------
    create table(:voice_scenario) do
      add :name, :string, size: 120, null: false
      add :slug, :string, size: 120, null: false
      add :description, :text, null: false, default: ""
      add :is_active, :boolean, null: false, default: true

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_scenario, [:name])
    create unique_index(:voice_scenario, [:slug])
    create index(:voice_scenario, [:is_active])

    # -------------------------------------------------------------------------
    # 3. voice_voiceprompt
    #    Partial unique: one active prompt per prompt_type
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # 4. voice_megaprompt
    #    unique (domain, version) + partial unique active-per-domain
    #    (created_by_id is plain bigint — no FK)
    # -------------------------------------------------------------------------
    create table(:voice_megaprompt) do
      add :domain, :string, size: 20, null: false
      add :name, :string, size: 255, null: false
      add :meta_prompt, :text, null: false
      add :is_active, :boolean, null: false, default: false
      add :version, :integer, null: false, default: 1
      # Plain bigint, no references
      add :created_by_id, :bigint, null: true

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_megaprompt, [:domain])
    create index(:voice_megaprompt, [:is_active])
    create index(:voice_megaprompt, [:created_by_id])

    create unique_index(:voice_megaprompt, [:domain, :version],
             name: "megaprompt_unique_domain_version"
           )

    create unique_index(:voice_megaprompt, [:domain],
             where: "is_active",
             name: "megaprompt_one_active_per_domain"
           )

    # -------------------------------------------------------------------------
    # 5. voice_globalsettings  (singleton — pk=1 enforced in application layer)
    #    default_methodology_id KEEPS its FK — both tables are in this DB.
    # -------------------------------------------------------------------------
    create table(:voice_globalsettings) do
      add :pre_call_offset_minutes, :integer, null: false, default: -60
      add :post_call_offset_minutes, :integer, null: false, default: 15
      add :retry_interval_minutes, :integer, null: false, default: 5
      add :max_context_tokens_warn, :integer, null: false, default: 50_000
      add :default_methodology_id,
          references(:voice_methodology, on_delete: :nilify_all),
          null: true

      # Only updated_at (mirrors per-tenant schema)
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_globalsettings, [:default_methodology_id])
  end
end
