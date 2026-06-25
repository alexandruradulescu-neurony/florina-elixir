defmodule Florina.CentralConfig do
  @moduledoc """
  Central (control-plane) configuration management.

  This context owns the canonical copies of all shared config:
  mega prompts, voice prompts, methodologies, scenarios, and default settings.

  All reads/writes here use `Florina.Repo` (the control-plane DB).

  ## Lifecycle

  - `seed_tenant/1`   — called by the Provisioner on new-tenant creation;
                        copies ALL canonical rows into the tenant DB preserving ids.
  - `publish_to/1`    — upserts canonical rows into one tenant, skipping rows
                        where `is_overridden = true` (tenant's custom value wins).
  - `publish_all/0`   — calls `publish_to/1` for every active tenant.

  ## Override semantics

  A tenant row with `is_overridden: true` is never touched by `publish_to`.
  The flag is `false` by default on all seed rows, so tenants start fully
  in sync with central config and can opt out row-by-row.
  """

  import Ecto.Query, only: [from: 2]

  alias Florina.Repo
  alias Florina.TenantRepo
  alias Florina.Tenants
  alias Florina.Tenants.ConnectionManager

  alias Florina.CentralConfig.{
    MegaPrompt,
    VoicePrompt,
    Methodology,
    Scenario,
    GlobalSettings
  }

  # Per-tenant schema modules (in the tenant DB)
  alias Florina.Prompts.MegaPrompt, as: TenantMegaPrompt
  alias Florina.Calls.VoicePrompt, as: TenantVoicePrompt
  alias Florina.Methodologies.Methodology, as: TenantMethodology
  alias Florina.Scenarios.Scenario, as: TenantScenario
  alias Florina.Settings.GlobalSettings, as: TenantGlobalSettings

  # ---------------------------------------------------------------------------
  # Canonical CRUD — MegaPrompts
  # ---------------------------------------------------------------------------

  def list_mega_prompts, do: Repo.all(MegaPrompt)

  def get_mega_prompt!(id), do: Repo.get!(MegaPrompt, id)

  def create_mega_prompt(attrs) do
    %MegaPrompt{}
    |> MegaPrompt.changeset(attrs)
    |> Repo.insert()
  end

  def update_mega_prompt(%MegaPrompt{} = mp, attrs) do
    mp
    |> MegaPrompt.changeset(attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Canonical CRUD — VoicePrompts
  # ---------------------------------------------------------------------------

  def list_voice_prompts, do: Repo.all(VoicePrompt)

  def get_voice_prompt!(id), do: Repo.get!(VoicePrompt, id)

  def create_voice_prompt(attrs) do
    %VoicePrompt{}
    |> VoicePrompt.changeset(attrs)
    |> Repo.insert()
  end

  def update_voice_prompt(%VoicePrompt{} = vp, attrs) do
    vp
    |> VoicePrompt.changeset(attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Canonical CRUD — Methodologies
  # ---------------------------------------------------------------------------

  def list_methodologies, do: Repo.all(Methodology)

  def get_methodology!(id), do: Repo.get!(Methodology, id)

  def create_methodology(attrs) do
    %Methodology{}
    |> Methodology.changeset(attrs)
    |> Repo.insert()
  end

  def update_methodology(%Methodology{} = m, attrs) do
    m
    |> Methodology.changeset(attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Canonical CRUD — Scenarios
  # ---------------------------------------------------------------------------

  def list_scenarios, do: Repo.all(Scenario)

  def get_scenario!(id), do: Repo.get!(Scenario, id)

  def create_scenario(attrs) do
    %Scenario{}
    |> Scenario.changeset(attrs)
    |> Repo.insert()
  end

  def update_scenario(%Scenario{} = s, attrs) do
    s
    |> Scenario.changeset(attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Canonical singleton — GlobalSettings (id=1, get-or-create)
  # ---------------------------------------------------------------------------

  @doc "Returns the canonical GlobalSettings singleton (id=1), creating it if absent."
  def get_settings do
    case Repo.get(GlobalSettings, 1) do
      nil ->
        %GlobalSettings{id: 1}
        |> Ecto.Changeset.change()
        |> Repo.insert(on_conflict: :nothing, conflict_target: :id)
        |> case do
          {:ok, row} -> row
          {:error, _} -> Repo.get!(GlobalSettings, 1)
        end

      row ->
        row
    end
  end

  def update_settings(attrs) do
    get_settings()
    |> GlobalSettings.changeset(attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # seed_tenant/1 — copy ALL canonical rows into a fresh tenant DB
  # ---------------------------------------------------------------------------

  @doc """
  Copies all canonical config rows into the given tenant's database,
  preserving ids (so tenant data that references config by id stays consistent).

  Uses `on_conflict: :replace_all` so calling this on an existing tenant is safe
  (it re-syncs without caring about prior state).  `is_overridden` is always
  reset to `false` on a seed — this is intentional: seed = "start from central".
  """
  def seed_tenant(slug) when is_binary(slug) do
    with {:ok, pid} <- ConnectionManager.ensure_started(slug) do
      TenantRepo.put_dynamic_repo(pid)
      do_seed()
      :ok
    end
  end

  defp do_seed do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # --- Methodologies ---
    methodologies = Repo.all(Methodology)

    methodology_rows =
      Enum.map(methodologies, fn m ->
        %{
          id: m.id,
          name: m.name,
          description: m.description,
          source_material: m.source_material,
          ai_summary: m.ai_summary,
          is_active: m.is_active,
          created_by_id: m.created_by_id,
          is_overridden: false,
          created_at: m.created_at || now,
          updated_at: now
        }
      end)

    TenantRepo.insert_all(TenantMethodology, methodology_rows,
      on_conflict: :replace_all,
      conflict_target: :id
    )

    # --- Scenarios ---
    scenarios = Repo.all(Scenario)

    scenario_rows =
      Enum.map(scenarios, fn s ->
        %{
          id: s.id,
          name: s.name,
          slug: s.slug,
          description: s.description || "",
          is_active: s.is_active,
          is_overridden: false,
          created_at: s.created_at || now,
          updated_at: now
        }
      end)

    TenantRepo.insert_all(TenantScenario, scenario_rows,
      on_conflict: :replace_all,
      conflict_target: :id
    )

    # --- VoicePrompts ---
    voice_prompts = Repo.all(VoicePrompt)

    voice_prompt_rows =
      Enum.map(voice_prompts, fn vp ->
        %{
          id: vp.id,
          name: vp.name,
          system_prompt: vp.system_prompt,
          first_message: vp.first_message,
          prompt_type: vp.prompt_type,
          is_active: vp.is_active,
          is_overridden: false,
          created_at: vp.created_at || now,
          updated_at: now
        }
      end)

    TenantRepo.insert_all(TenantVoicePrompt, voice_prompt_rows,
      on_conflict: :replace_all,
      conflict_target: :id
    )

    # --- MegaPrompts ---
    mega_prompts = Repo.all(MegaPrompt)

    mega_prompt_rows =
      Enum.map(mega_prompts, fn mp ->
        %{
          id: mp.id,
          domain: mp.domain,
          name: mp.name,
          meta_prompt: mp.meta_prompt,
          is_active: mp.is_active,
          version: mp.version,
          created_by_id: mp.created_by_id,
          is_overridden: false,
          created_at: mp.created_at || now,
          updated_at: now
        }
      end)

    TenantRepo.insert_all(TenantMegaPrompt, mega_prompt_rows,
      on_conflict: :replace_all,
      conflict_target: :id
    )

    # --- GlobalSettings (singleton id=1) ---
    settings = get_settings()

    settings_row = %{
      id: settings.id,
      pre_call_offset_minutes: settings.pre_call_offset_minutes,
      post_call_offset_minutes: settings.post_call_offset_minutes,
      retry_interval_minutes: settings.retry_interval_minutes,
      max_context_tokens_warn: settings.max_context_tokens_warn,
      default_methodology_id: settings.default_methodology_id,
      is_overridden: false,
      updated_at: now
    }

    TenantRepo.insert_all(TenantGlobalSettings, [settings_row],
      on_conflict: :replace_all,
      conflict_target: :id
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # publish_to/1 — upsert canonical rows into one tenant, skipping overrides
  # ---------------------------------------------------------------------------

  @doc """
  Upserts canonical config into a single tenant's database.

  For each canonical row:
  - If the tenant has a row with `is_overridden: true` → skip (tenant owns it).
  - Otherwise → upsert by id (insert if missing, update content if present).

  `is_overridden` is never changed by publish — a tenant sets it explicitly
  to opt out of future syncs.
  """
  def publish_to(slug) when is_binary(slug) do
    with {:ok, pid} <- ConnectionManager.ensure_started(slug) do
      TenantRepo.put_dynamic_repo(pid)
      do_publish()
      :ok
    end
  end

  defp do_publish do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    publish_table(
      Repo.all(Methodology),
      TenantMethodology,
      fn m ->
        %{
          id: m.id,
          name: m.name,
          description: m.description,
          source_material: m.source_material,
          ai_summary: m.ai_summary,
          is_active: m.is_active,
          created_by_id: m.created_by_id,
          created_at: m.created_at || now,
          updated_at: now
        }
      end
    )

    publish_table(
      Repo.all(Scenario),
      TenantScenario,
      fn s ->
        %{
          id: s.id,
          name: s.name,
          slug: s.slug,
          description: s.description || "",
          is_active: s.is_active,
          created_at: s.created_at || now,
          updated_at: now
        }
      end
    )

    publish_table(
      Repo.all(VoicePrompt),
      TenantVoicePrompt,
      fn vp ->
        %{
          id: vp.id,
          name: vp.name,
          system_prompt: vp.system_prompt,
          first_message: vp.first_message,
          prompt_type: vp.prompt_type,
          is_active: vp.is_active,
          created_at: vp.created_at || now,
          updated_at: now
        }
      end
    )

    publish_table(
      Repo.all(MegaPrompt),
      TenantMegaPrompt,
      fn mp ->
        %{
          id: mp.id,
          domain: mp.domain,
          name: mp.name,
          meta_prompt: mp.meta_prompt,
          is_active: mp.is_active,
          version: mp.version,
          created_by_id: mp.created_by_id,
          created_at: mp.created_at || now,
          updated_at: now
        }
      end
    )

    # GlobalSettings singleton
    settings = get_settings()

    tenant_settings = TenantRepo.get(TenantGlobalSettings, settings.id)

    unless tenant_settings && tenant_settings.is_overridden do
      row = %{
        id: settings.id,
        pre_call_offset_minutes: settings.pre_call_offset_minutes,
        post_call_offset_minutes: settings.post_call_offset_minutes,
        retry_interval_minutes: settings.retry_interval_minutes,
        max_context_tokens_warn: settings.max_context_tokens_warn,
        default_methodology_id: settings.default_methodology_id,
        updated_at: now
      }

      TenantRepo.insert_all(TenantGlobalSettings, [row],
        on_conflict:
          {:replace,
           [
             :pre_call_offset_minutes,
             :post_call_offset_minutes,
             :retry_interval_minutes,
             :max_context_tokens_warn,
             :default_methodology_id,
             :updated_at
           ]},
        conflict_target: :id
      )
    end

    :ok
  end

  # Upserts canonical rows into a tenant table, skipping overridden rows.
  defp publish_table(canonical_rows, tenant_schema, row_builder) do
    # Fetch overridden ids in one query
    overridden_ids =
      TenantRepo.all(from r in tenant_schema, where: r.is_overridden == true, select: r.id)
      |> MapSet.new()

    rows_to_upsert =
      canonical_rows
      |> Enum.reject(fn row -> MapSet.member?(overridden_ids, row.id) end)
      |> Enum.map(row_builder)

    if rows_to_upsert != [] do
      # Determine which fields to replace: all keys except :id and :is_overridden
      replace_fields =
        rows_to_upsert
        |> List.first()
        |> Map.keys()
        |> Enum.reject(&(&1 in [:id]))

      TenantRepo.insert_all(tenant_schema, rows_to_upsert,
        on_conflict: {:replace, replace_fields},
        conflict_target: :id
      )
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # publish_all/0 — publish to every active tenant
  # ---------------------------------------------------------------------------

  @doc "Publishes canonical config to all active tenants."
  def publish_all do
    Tenants.list()
    |> Enum.filter(& &1.active)
    |> Enum.each(fn tenant -> publish_to(tenant.slug) end)

    :ok
  end
end
