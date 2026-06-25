defmodule Florina.CentralConfig do
  @moduledoc """
  Central (control-plane) configuration management.

  This context owns the canonical copies of all shared config:
  mega prompts, voice prompts, methodologies, scenarios, and default settings.

  All reads/writes here use `Florina.Repo` (the control-plane DB).

  ## Lifecycle

  - `seed_tenant/1`   — called by the Provisioner on new-tenant creation;
                        copies ALL canonical rows into the tenant DB preserving ids.
                        Rows already marked `is_overridden: true` are left untouched.
  - `publish_to/1`    — upserts canonical rows into one tenant, skipping rows
                        where `is_overridden = true` (tenant's custom value wins).
  - `publish_all/0`   — calls `publish_to/1` for every active tenant.
                        Returns a summary map `{:ok, %{published: n, failed: [...]}}`.

  ## Override semantics

  A tenant row with `is_overridden: true` is never touched by `publish_to` or
  `seed_tenant`. The per-tenant contexts (`Methodologies`, `Scenarios`, etc.)
  automatically set `is_overridden: true` when a tenant edits or creates a local
  row, so publish won't overwrite those tenant customisations.

  The flag is `false` by default on seed rows for freshly provisioned tenants
  (no existing rows), so new tenants start fully in sync with central config.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Florina.Repo
  alias Florina.TenantRepo
  alias Florina.Tenants

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

  Rows already marked `is_overridden: true` in the tenant DB are skipped, so
  re-seeding an existing tenant (e.g. via Retry/re-provision) does NOT destroy
  customisations the tenant has made. Fresh tenants (no rows yet) get everything.
  """
  def seed_tenant(slug) when is_binary(slug) do
    case Tenants.get_by_slug(slug) do
      nil -> {:error, :unknown_tenant}
      tenant -> Tenants.with_prefix(tenant, fn -> do_seed() end)
    end
  end

  defp do_seed do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # --- Methodologies ---
    methodologies = Repo.all(Methodology)

    overridden_methodology_ids =
      TenantRepo.all(from r in TenantMethodology, where: r.is_overridden == true, select: r.id)
      |> MapSet.new()

    methodology_rows =
      methodologies
      |> Enum.reject(fn m -> MapSet.member?(overridden_methodology_ids, m.id) end)
      |> Enum.map(fn m ->
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

    if methodology_rows != [] do
      TenantRepo.insert_all(TenantMethodology, methodology_rows,
        on_conflict: :replace_all,
        conflict_target: :id
      )
    end

    # --- Scenarios ---
    scenarios = Repo.all(Scenario)

    overridden_scenario_ids =
      TenantRepo.all(from r in TenantScenario, where: r.is_overridden == true, select: r.id)
      |> MapSet.new()

    scenario_rows =
      scenarios
      |> Enum.reject(fn s -> MapSet.member?(overridden_scenario_ids, s.id) end)
      |> Enum.map(fn s ->
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

    if scenario_rows != [] do
      TenantRepo.insert_all(TenantScenario, scenario_rows,
        on_conflict: :replace_all,
        conflict_target: :id
      )
    end

    # --- VoicePrompts ---
    voice_prompts = Repo.all(VoicePrompt)

    overridden_voice_prompt_ids =
      TenantRepo.all(from r in TenantVoicePrompt, where: r.is_overridden == true, select: r.id)
      |> MapSet.new()

    voice_prompt_rows =
      voice_prompts
      |> Enum.reject(fn vp -> MapSet.member?(overridden_voice_prompt_ids, vp.id) end)
      |> Enum.map(fn vp ->
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

    if voice_prompt_rows != [] do
      TenantRepo.insert_all(TenantVoicePrompt, voice_prompt_rows,
        on_conflict: :replace_all,
        conflict_target: :id
      )
    end

    # --- MegaPrompts ---
    mega_prompts = Repo.all(MegaPrompt)

    overridden_mega_prompt_ids =
      TenantRepo.all(from r in TenantMegaPrompt, where: r.is_overridden == true, select: r.id)
      |> MapSet.new()

    mega_prompt_rows =
      mega_prompts
      |> Enum.reject(fn mp -> MapSet.member?(overridden_mega_prompt_ids, mp.id) end)
      |> Enum.map(fn mp ->
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

    if mega_prompt_rows != [] do
      TenantRepo.insert_all(TenantMegaPrompt, mega_prompt_rows,
        on_conflict: :replace_all,
        conflict_target: :id
      )
    end

    # --- GlobalSettings (singleton id=1) ---
    settings = get_settings()

    tenant_settings = TenantRepo.get(TenantGlobalSettings, settings.id)

    unless tenant_settings && tenant_settings.is_overridden do
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
    end

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
    case Tenants.get_by_slug(slug) do
      nil ->
        {:error, :unknown_tenant}

      tenant ->
        Tenants.with_prefix(tenant, fn ->
          TenantRepo.transaction(fn -> do_publish() end)
        end)
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

  # Upserts canonical rows into a tenant table, skipping rows the tenant has
  # overridden. `:is_overridden` is explicitly excluded from replace_fields so
  # that publish never clears a tenant's override flag, even if it appears in
  # the source map.
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
      # Replace all fields except :id (primary key) and :is_overridden (tenant owns it).
      replace_fields =
        rows_to_upsert
        |> List.first()
        |> Map.keys()
        |> Enum.reject(&(&1 in [:id, :is_overridden]))

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

  @doc """
  Publishes canonical config to all active tenants (status == "active" AND active == true).

  Per-tenant failures are isolated: one tenant's error is logged and does not
  abort publishing to the others. Returns a summary:

      {:ok, %{published: n, failed: [%{slug: "...", reason: "..."}]}}
  """
  def publish_all do
    tenants = Tenants.list_active()

    results =
      Enum.map(tenants, fn tenant ->
        try do
          case publish_to(tenant.slug) do
            {:ok, _} ->
              {:published, tenant.slug}

            {:error, reason} ->
              Logger.error(
                "CentralConfig.publish_all: failed for #{tenant.slug}: #{inspect(reason)}"
              )

              {:failed, tenant.slug, inspect(reason)}
          end
        rescue
          e ->
            reason = Exception.message(e)
            Logger.error("CentralConfig.publish_all: exception for #{tenant.slug}: #{reason}")
            {:failed, tenant.slug, reason}
        catch
          kind, value ->
            reason = "#{kind}: #{inspect(value)}"
            Logger.error("CentralConfig.publish_all: throw for #{tenant.slug}: #{reason}")
            {:failed, tenant.slug, reason}
        end
      end)

    published = Enum.count(results, &match?({:published, _}, &1))

    failed =
      results
      |> Enum.filter(&match?({:failed, _, _}, &1))
      |> Enum.map(fn {:failed, slug, reason} -> %{slug: slug, reason: reason} end)

    {:ok, %{published: published, failed: failed}}
  end
end
