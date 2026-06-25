defmodule Florina.TenantRepo.Migrations.TenantBaseline do
  @moduledoc """
  Squashed baseline for a tenant's schema (`tenant_<id>`).

  This single migration recreates the FINAL state that the previous 13
  incremental tenant migrations converged on. It is intentionally **pure Ecto
  DSL** (`create table`, `create index`, `alter table`) — no raw
  `execute("ALTER TABLE ...")` / `SET search_path`. Ecto's `create table(...)`
  honours the migrator's `:prefix` option automatically, so every object lands
  in the right `tenant_<id>` schema without the migration ever touching the
  process-level search path (which `Ecto.Migrator` runs in a separate process,
  where a caller's `Process.put` is invisible).

  History collapsed here, in order:

    1. create_tenant_markers
    2. create_voice_callattempt
    3. create_backend_schema (all voice_* core tables + circular FK resolution)
    4. create_config_overrides (is_overridden on the 5 config tables)
    5. encrypt_sensitive_fields — folded in: the encrypted columns are simply
       created as `:binary` (bytea) here, so the type-conversion dance is gone.
    6. add_active_to_voice_user — folded into voice_user.
    7. create_oauth_credentials.
    8. create_calendar_events.
    9. drop_voice_googleoauthcredential — folded in: that table is never created.
   10. add_provider_to_voice_visit — folded into voice_visit.
   11. reencrypt_generationrun_plaintext — dropped: data repair, no data exists.
   12. backfill_visit_provider — dropped: data backfill, no data exists.
   13. unique_visit_per_event — folded in as the partial unique index.

  Cloak-encrypted columns (stored as bytea / `:binary`):
    * voice_generationrun: claude_request, claude_response, error,
      context_bundle, parsed_outputs
    * oauth_credentials: access_token, refresh_token, client_secret
  """
  use Ecto.Migration

  def change do
    # =========================================================================
    # tenant_markers — throwaway proof-of-isolation table (leakage test/whoami)
    # =========================================================================
    create table(:tenant_markers) do
      add :label, :string, null: false
      timestamps(type: :utc_datetime)
    end

    # =========================================================================
    # voice_user (no default_methodology_id yet — circular ref with methodology)
    # =========================================================================
    create table(:voice_user) do
      add :username, :string, size: 150, null: false
      add :email, :string, size: 254
      add :first_name, :string, size: 150
      add :last_name, :string, size: 150
      add :pipedrive_user_id, :integer
      add :phone_number, :string, size: 20
      add :is_sales_agent, :boolean, null: false, default: false
      add :active, :boolean, null: false, default: true

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_user, [:username])

    # =========================================================================
    # voice_methodology (created_by_id -> voice_user)
    # =========================================================================
    create table(:voice_methodology) do
      add :name, :string, size: 255, null: false
      add :description, :text
      add :source_material, :string, size: 255
      add :ai_summary, :text
      add :is_active, :boolean, null: false, default: true
      add :is_overridden, :boolean, null: false, default: false
      add :created_by_id, references(:voice_user, on_delete: :nilify_all), null: true

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_methodology, [:is_active])
    create index(:voice_methodology, [:created_by_id])

    # Resolve circular FK: add default_methodology_id to voice_user.
    alter table(:voice_user) do
      add :default_methodology_id,
          references(:voice_methodology, on_delete: :nilify_all),
          null: true
    end

    create index(:voice_user, [:default_methodology_id])

    # =========================================================================
    # voice_client
    # =========================================================================
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

    # =========================================================================
    # voice_scenario
    # =========================================================================
    create table(:voice_scenario) do
      add :name, :string, size: 120, null: false
      add :slug, :string, size: 120, null: false
      add :description, :text, null: false, default: ""
      add :is_active, :boolean, null: false, default: true
      add :is_overridden, :boolean, null: false, default: false

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_scenario, [:name])
    create unique_index(:voice_scenario, [:slug])
    create index(:voice_scenario, [:is_active])

    # =========================================================================
    # voice_visit
    # =========================================================================
    create table(:voice_visit) do
      add :agent_id, references(:voice_user, on_delete: :delete_all), null: false
      add :client_id, references(:voice_client, on_delete: :delete_all), null: false
      add :methodology_id, references(:voice_methodology, on_delete: :nilify_all), null: true
      add :scenario_id, references(:voice_scenario, on_delete: :nilify_all), null: true

      add :calendar_event_id, :string, size: 255
      add :provider, :string
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

    # Backstop visit idempotency: at most one synced visit per
    # (agent, provider, calendar_event). Manual visits (no calendar_event_id)
    # stay unconstrained via the partial WHERE.
    create unique_index(:voice_visit, [:agent_id, :provider, :calendar_event_id],
             where: "calendar_event_id IS NOT NULL",
             name: :voice_visit_agent_provider_event_uidx
           )

    # =========================================================================
    # voice_callattempt (visit_id -> voice_visit)
    # =========================================================================
    create table(:voice_callattempt) do
      add :visit_id, references(:voice_visit, type: :bigint, on_delete: :delete_all), null: true
      add :phase, :string, size: 20
      add :scheduled_offset_minutes, :integer
      add :external_call_id, :string, size: 100
      add :status, :string, size: 20, null: false, default: "SCHEDULED"
      add :recording_url, :string
      add :transcript, :text
      add :summary, :text
      add :summary_title, :string
      add :analysis, :map, null: false, default: %{}
      add :scheduled_time, :utc_datetime
      add :executed_at, :utc_datetime
      add :retry_count, :integer, null: false, default: 0

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_callattempt, [:external_call_id])
    create index(:voice_callattempt, [:status])
    create index(:voice_callattempt, [:visit_id], name: "voice_calla_visit_idx")
    create index(:voice_callattempt, [:visit_id, :phase], name: "voice_calla_visit_phase_idx")

    create index(:voice_callattempt, [:scheduled_time, :status],
             name: "voice_calla_schedul_status_idx"
           )

    # =========================================================================
    # voice_voiceprompt (one active prompt per prompt_type)
    # =========================================================================
    create table(:voice_voiceprompt) do
      add :name, :string, size: 100, null: false
      add :system_prompt, :text, null: false
      add :first_message, :text
      add :prompt_type, :string, size: 20, null: false, default: "PRE"
      add :is_active, :boolean, null: false, default: true
      add :is_overridden, :boolean, null: false, default: false

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_voiceprompt, [:prompt_type],
             where: "is_active",
             name: "unique_active_prompt"
           )

    # =========================================================================
    # voice_megaprompt (unique (domain, version) + one active per domain)
    # =========================================================================
    create table(:voice_megaprompt) do
      add :domain, :string, size: 20, null: false
      add :name, :string, size: 255, null: false
      add :meta_prompt, :text, null: false
      add :is_active, :boolean, null: false, default: false
      add :version, :integer, null: false, default: 1
      add :is_overridden, :boolean, null: false, default: false
      add :created_by_id, references(:voice_user, on_delete: :nilify_all), null: true

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

    # =========================================================================
    # voice_generationrun — Cloak-encrypted PII columns are :binary (bytea)
    # =========================================================================
    create table(:voice_generationrun) do
      add :visit_id, references(:voice_visit, on_delete: :delete_all), null: true
      add :client_id, references(:voice_client, on_delete: :delete_all), null: true
      add :mega_prompt_id, references(:voice_megaprompt, on_delete: :restrict), null: true
      add :created_by_id, references(:voice_user, on_delete: :nilify_all), null: true

      add :domain, :string, size: 20, null: false
      add :triggered_by, :string, size: 20, null: false

      # Cloak-encrypted (AES-GCM-256) — ciphertext stored as bytea.
      add :context_bundle, :binary, null: false
      add :claude_request, :binary, null: false
      add :claude_response, :binary, null: false
      add :parsed_outputs, :binary, null: false
      add :error, :binary, null: false

      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :success, :boolean, null: false, default: false

      # Only created_at (no updated_at in the Django model).
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_generationrun, [:domain])
    create index(:voice_generationrun, [:success])
    create index(:voice_generationrun, [:created_at])
    create index(:voice_generationrun, [:visit_id], name: "voice_genrun_visit_idx")
    create index(:voice_generationrun, [:domain, :success], name: "voice_genrun_domsucc_idx")

    # =========================================================================
    # voice_globalsettings (singleton — pk=1 enforced in the application layer)
    # =========================================================================
    create table(:voice_globalsettings) do
      add :pre_call_offset_minutes, :integer, null: false, default: -60
      add :post_call_offset_minutes, :integer, null: false, default: 15
      add :retry_interval_minutes, :integer, null: false, default: 5
      add :max_context_tokens_warn, :integer, null: false, default: 50_000
      add :is_overridden, :boolean, null: false, default: false
      add :default_methodology_id, references(:voice_methodology, on_delete: :nilify_all), null: true

      # Only updated_at (Django auto_now); no inserted_at.
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    # =========================================================================
    # voice_activitylog (only `timestamp`, no updated_at)
    # =========================================================================
    create table(:voice_activitylog) do
      add :visit_id, references(:voice_visit, on_delete: :nilify_all), null: true
      add :user_id, references(:voice_user, on_delete: :nilify_all), null: true

      add :action, :string, size: 100, null: false
      add :details, :map, null: false, default: %{}
      add :level, :string, size: 10, null: false, default: "INFO"
      add :timestamp, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:voice_activitylog, [:timestamp])
    create index(:voice_activitylog, [:level])
    create index(:voice_activitylog, [:visit_id])
    create index(:voice_activitylog, [:user_id])

    # =========================================================================
    # voice_googlecalendarwatch (only created_at)
    # =========================================================================
    create table(:voice_googlecalendarwatch) do
      add :user_id, references(:voice_user, on_delete: :delete_all), null: false

      add :channel_id, :string, size: 255, null: false
      add :resource_id, :string, size: 255, null: false
      add :expiration, :utc_datetime, null: false
      add :token, :string, size: 64, null: false, default: ""
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:voice_googlecalendarwatch, [:channel_id])
    create index(:voice_googlecalendarwatch, [:user_id])
    create index(:voice_googlecalendarwatch, [:expiration])

    # =========================================================================
    # oauth_credentials — Cloak-encrypted token columns are :binary (bytea)
    # =========================================================================
    create table(:oauth_credentials) do
      add :user_id, references(:voice_user, on_delete: :delete_all)
      add :provider, :string, null: false
      add :purpose, :string, null: false, default: "agent_calendar"
      add :email, :string, size: 254
      # Cloak-encrypted (AES-GCM-256) — ciphertext stored as bytea.
      add :access_token, :binary, null: false
      add :refresh_token, :binary
      add :client_id, :string, size: 255
      add :client_secret, :binary
      add :token_uri, :string, size: 255
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime

      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:oauth_credentials, [:user_id])

    # One calendar credential per (user, provider, purpose).
    create unique_index(:oauth_credentials, [:provider, :purpose, :user_id],
             name: :oauth_credentials_provider_purpose_user_index
           )

    # =========================================================================
    # calendar_events
    # =========================================================================
    create table(:calendar_events) do
      add :user_id, references(:voice_user, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :external_event_id, :string, size: 512, null: false
      add :title, :string, size: 1024
      add :description, :text
      add :location, :string, size: 1024
      add :start_time, :utc_datetime, null: false
      add :end_time, :utc_datetime, null: false
      add :attendees, {:array, :map}, null: false, default: []
      add :status, :string, size: 50
      add :raw, :map
      add :synced_at, :utc_datetime
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:calendar_events, [:start_time])

    create unique_index(:calendar_events, [:user_id, :provider, :external_event_id],
             name: :calendar_events_user_provider_extid_index
           )
  end
end
