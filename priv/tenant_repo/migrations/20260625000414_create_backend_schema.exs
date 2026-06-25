defmodule Florina.TenantRepo.Migrations.CreateBackendSchema do
  @moduledoc """
  One-shot migration creating all backend tables in dependency order.

  Handles the circular FK between voice_user and voice_methodology:
    1. Create voice_user WITHOUT default_methodology_id
    2. Create voice_methodology (with created_by_id -> voice_user)
    3. ALTER voice_user to add default_methodology_id -> voice_methodology

  voice_callattempt already exists from a prior migration — we add the
  visit_id -> voice_visit FK constraint here (using add_if_not_exists to be
  safe, even though visit_id column was pre-created without a FK).
  """
  use Ecto.Migration

  def change do
    # -------------------------------------------------------------------------
    # 1. voice_user (no default_methodology_id yet — circular ref)
    # -------------------------------------------------------------------------
    create table(:voice_user) do
      add :username, :string, size: 150, null: false
      add :email, :string, size: 254
      add :first_name, :string, size: 150
      add :last_name, :string, size: 150
      add :pipedrive_user_id, :integer
      add :phone_number, :string, size: 20
      add :is_sales_agent, :boolean, null: false, default: false
      # default_methodology_id added below after voice_methodology exists

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_user, [:username])

    # -------------------------------------------------------------------------
    # 2. voice_methodology (created_by_id -> voice_user)
    # -------------------------------------------------------------------------
    create table(:voice_methodology) do
      add :name, :string, size: 255, null: false
      add :description, :text
      # Django FileField stored as string path
      add :source_material, :string, size: 255
      add :ai_summary, :text
      add :is_active, :boolean, null: false, default: true
      add :created_by_id,
          references(:voice_user, on_delete: :nilify_all),
          null: true

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_methodology, [:is_active])
    create index(:voice_methodology, [:created_by_id])

    # -------------------------------------------------------------------------
    # 3. Resolve circular FK: add default_methodology_id to voice_user
    # -------------------------------------------------------------------------
    alter table(:voice_user) do
      add :default_methodology_id,
          references(:voice_methodology, on_delete: :nilify_all),
          null: true
    end

    create index(:voice_user, [:default_methodology_id])

    # -------------------------------------------------------------------------
    # 4. voice_client
    # -------------------------------------------------------------------------
    create table(:voice_client) do
      add :crm_id, :string, size: 100, null: false
      add :name, :string, size: 255, null: false
      add :domain, :string, size: 255
      add :industry, :string, size: 255
      add :status, :string, size: 20, null: false, default: "nou"
      add :contacts, {:array, :map}, null: false, default: []
      add :deal_history, {:array, :map}, null: false, default: []
      add :interaction_history, {:array, :map}, null: false, default: []
      add :ai_summary, :text
      add :lessons_learned, :text, null: false, default: ""
      add :raw_data, :map, null: false, default: %{}
      add :last_synced_at, :utc_datetime

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_client, [:crm_id])
    create index(:voice_client, [:domain])
    create index(:voice_client, [:name])
    create index(:voice_client, [:status])

    # -------------------------------------------------------------------------
    # 5. voice_scenario
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
    # 6. voice_visit  (agent -> voice_user, client -> voice_client,
    #                  methodology -> voice_methodology, scenario -> voice_scenario)
    # -------------------------------------------------------------------------
    create table(:voice_visit) do
      add :agent_id,
          references(:voice_user, on_delete: :delete_all),
          null: false

      add :client_id,
          references(:voice_client, on_delete: :delete_all),
          null: false

      add :methodology_id,
          references(:voice_methodology, on_delete: :nilify_all),
          null: true

      add :scenario_id,
          references(:voice_scenario, on_delete: :nilify_all),
          null: true

      add :calendar_event_id, :string, size: 255
      add :title, :string, size: 255, null: false
      add :start_time, :utc_datetime, null: false
      add :end_time, :utc_datetime, null: false
      add :attendees, {:array, :map}, null: false, default: []
      add :crm_deal_id, :string, size: 100
      add :manager_notes, :text
      add :status, :string, size: 20, null: false, default: "PLANNED"
      add :pre_call_prompt, :text
      add :pre_call_first_message, :text, null: false, default: ""
      add :post_call_prompt, :text
      add :post_call_first_message, :text, null: false, default: ""
      add :pre_call_prompt_locked, :boolean, null: false, default: false
      add :pre_call_first_message_locked, :boolean, null: false, default: false
      add :post_call_prompt_locked, :boolean, null: false, default: false
      add :post_call_first_message_locked, :boolean, null: false, default: false
      add :post_call_summary, :text
      add :crm_synced, :boolean, null: false, default: false

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_visit, [:start_time])
    create index(:voice_visit, [:end_time])
    create index(:voice_visit, [:status])
    create index(:voice_visit, [:calendar_event_id])
    create index(:voice_visit, [:agent_id, :start_time])
    create index(:voice_visit, [:client_id], name: "voice_visit_client_idx")
    create index(:voice_visit, [:agent_id, :status], name: "voice_visit_agent_status_idx")

    # -------------------------------------------------------------------------
    # 7. Add visit_id FK to voice_callattempt now that voice_visit exists.
    #    The column itself already exists (from the prior migration).
    #    We add the FK constraint with alter + modify to reference voice_visit.
    #    Using modify/3 to attach the FK without touching other columns.
    # -------------------------------------------------------------------------
    alter table(:voice_callattempt) do
      modify :visit_id,
             references(:voice_visit, type: :bigint, on_delete: :delete_all),
             null: true,
             from: :bigint
    end

    create index(:voice_callattempt, [:visit_id], name: "voice_calla_visit_idx")
    create index(:voice_callattempt, [:visit_id, :phase], name: "voice_calla_visit_phase_idx")

    create index(:voice_callattempt, [:scheduled_time, :status],
             name: "voice_calla_schedul_status_idx"
           )

    # -------------------------------------------------------------------------
    # 8. voice_voiceprompt
    #    Partial unique index: one active prompt per prompt_type
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
    # 9. voice_megaprompt
    #    unique (domain, version) + partial unique active-per-domain
    # -------------------------------------------------------------------------
    create table(:voice_megaprompt) do
      add :domain, :string, size: 20, null: false
      add :name, :string, size: 255, null: false
      add :meta_prompt, :text, null: false
      add :is_active, :boolean, null: false, default: false
      add :version, :integer, null: false, default: 1
      add :created_by_id,
          references(:voice_user, on_delete: :nilify_all),
          null: true

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
    # 10. voice_generationrun
    # -------------------------------------------------------------------------
    create table(:voice_generationrun) do
      add :visit_id,
          references(:voice_visit, on_delete: :delete_all),
          null: true

      add :client_id,
          references(:voice_client, on_delete: :delete_all),
          null: true

      add :mega_prompt_id,
          references(:voice_megaprompt, on_delete: :restrict),
          null: true

      add :created_by_id,
          references(:voice_user, on_delete: :nilify_all),
          null: true

      add :domain, :string, size: 20, null: false
      add :triggered_by, :string, size: 20, null: false

      # TODO: encrypt at rest (Cloak)
      add :context_bundle, :map, null: false, default: %{}
      # TODO: encrypt at rest (Cloak)
      add :claude_request, :text, null: false, default: ""
      # TODO: encrypt at rest (Cloak)
      add :claude_response, :text, null: false, default: ""
      # TODO: encrypt at rest (Cloak)
      add :parsed_outputs, :map, null: false, default: %{}
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :success, :boolean, null: false, default: false
      # TODO: encrypt at rest (Cloak)
      add :error, :text, null: false, default: ""

      # Only created_at (no updated_at in Django model)
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_generationrun, [:domain])
    create index(:voice_generationrun, [:success])
    create index(:voice_generationrun, [:created_at])
    create index(:voice_generationrun, [:visit_id], name: "voice_genrun_visit_idx")

    create index(:voice_generationrun, [:domain, :success],
             name: "voice_genrun_domsucc_idx"
           )

    # -------------------------------------------------------------------------
    # 11. voice_globalsettings  (singleton — pk=1 enforced in application layer)
    # -------------------------------------------------------------------------
    create table(:voice_globalsettings) do
      add :pre_call_offset_minutes, :integer, null: false, default: -60
      add :post_call_offset_minutes, :integer, null: false, default: 15
      add :retry_interval_minutes, :integer, null: false, default: 5
      add :max_context_tokens_warn, :integer, null: false, default: 50_000
      add :default_methodology_id,
          references(:voice_methodology, on_delete: :nilify_all),
          null: true

      # Only updated_at (Django auto_now); no inserted_at.
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    # -------------------------------------------------------------------------
    # 12. voice_activitylog  (only `timestamp`, no updated_at)
    # -------------------------------------------------------------------------
    create table(:voice_activitylog) do
      add :visit_id,
          references(:voice_visit, on_delete: :nilify_all),
          null: true

      add :user_id,
          references(:voice_user, on_delete: :nilify_all),
          null: true

      add :action, :string, size: 100, null: false
      add :details, :map, null: false, default: %{}
      add :level, :string, size: 10, null: false, default: "INFO"
      add :timestamp, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_activitylog, [:timestamp])
    create index(:voice_activitylog, [:level])
    create index(:voice_activitylog, [:visit_id])
    create index(:voice_activitylog, [:user_id])

    # -------------------------------------------------------------------------
    # 13. voice_googlecalendarwatch  (only created_at)
    # -------------------------------------------------------------------------
    create table(:voice_googlecalendarwatch) do
      add :user_id,
          references(:voice_user, on_delete: :delete_all),
          null: false

      add :channel_id, :string, size: 255, null: false
      add :resource_id, :string, size: 255, null: false
      add :expiration, :utc_datetime, null: false
      add :token, :string, size: 64, null: false, default: ""
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_googlecalendarwatch, [:channel_id])
    create index(:voice_googlecalendarwatch, [:user_id])
    create index(:voice_googlecalendarwatch, [:expiration])

    # -------------------------------------------------------------------------
    # 14. voice_googleoauthcredential  (one per user — OneToOneField)
    # -------------------------------------------------------------------------
    create table(:voice_googleoauthcredential) do
      add :user_id,
          references(:voice_user, on_delete: :delete_all),
          null: false

      # TODO: encrypt at rest (Cloak)
      add :token, :text, null: false
      # TODO: encrypt at rest (Cloak)
      add :refresh_token, :text, null: false
      add :token_uri, :string, null: false, default: "https://oauth2.googleapis.com/token"
      add :client_id, :string, size: 255, null: false
      # TODO: encrypt at rest (Cloak)
      add :client_secret, :text, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    # OneToOneField: unique constraint on user_id
    create unique_index(:voice_googleoauthcredential, [:user_id])
  end
end
