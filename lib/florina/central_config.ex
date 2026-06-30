defmodule Florina.CentralConfig do
  @moduledoc """
  Central (control-plane) configuration management.

  This context owns the canonical copies of all shared config:
  mega prompts, methodologies, scenarios, and default settings.

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
    Methodology,
    Scenario,
    GlobalSettings
  }

  # Per-tenant schema modules (in the tenant DB)
  alias Florina.Prompts.MegaPrompt, as: TenantMegaPrompt
  alias Florina.Methodologies.Methodology, as: TenantMethodology
  alias Florina.Scenarios.Scenario, as: TenantScenario
  alias Florina.Settings.GlobalSettings, as: TenantGlobalSettings

  # ---------------------------------------------------------------------------
  # Canonical CRUD — MegaPrompts
  # ---------------------------------------------------------------------------

  def list_mega_prompts, do: Repo.all(MegaPrompt)

  def get_mega_prompt!(id), do: Repo.get!(MegaPrompt, id)

  def get_mega_prompt(id), do: Repo.get(MegaPrompt, id)

  @doc "Delete a canonical mega prompt (control-plane only; tenant copies persist)."
  def delete_mega_prompt(%MegaPrompt{} = mp), do: Repo.delete(mp)

  def create_mega_prompt(attrs) do
    %MegaPrompt{}
    |> MegaPrompt.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a new mega prompt for a domain and make it the ACTIVE canonical one.

  The version is auto-assigned (next after the domain's current highest) and any
  currently-active prompt for the same domain is stepped down to inactive, so the
  one-active-per-domain rule always holds and the caller never manages versions.
  Runs in a transaction (a failed insert rolls the deactivation back). `attrs` needs
  `domain`, `name`, `meta_prompt`. Returns `{:ok, mega_prompt}`,
  `{:error, :invalid_domain}`, or `{:error, changeset}`.
  """
  def create_and_activate_mega_prompt(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, domain} <- fetch_domain(attrs["domain"]) do
      Repo.transaction(fn ->
        # Step the current active prompt for this domain down to inactive so the
        # new one can be the single active version.
        from(m in MegaPrompt, where: m.domain == ^domain and m.is_active == true)
        |> Repo.update_all(set: [is_active: false])

        next_version =
          (Repo.aggregate(from(m in MegaPrompt, where: m.domain == ^domain), :max, :version) || 0) +
            1

        attrs = attrs |> Map.put("is_active", true) |> Map.put("version", next_version)

        case %MegaPrompt{} |> MegaPrompt.changeset(attrs) |> Repo.insert() do
          {:ok, mp} -> mp
          {:error, cs} -> Repo.rollback(cs)
        end
      end)
    end
  end

  # Resolve a domain param (string from a form, or atom) to the enum atom, or
  # {:error, :invalid_domain} for anything not in the allowed set.
  defp fetch_domain(raw) do
    values = Florina.Enums.mega_prompt_domain_values()

    cond do
      is_atom(raw) and Keyword.has_key?(values, raw) ->
        {:ok, raw}

      is_binary(raw) ->
        case Enum.find(values, fn {_atom, value} -> value == raw end) do
          {atom, _value} -> {:ok, atom}
          nil -> {:error, :invalid_domain}
        end

      true ->
        {:error, :invalid_domain}
    end
  end

  def update_mega_prompt(%MegaPrompt{} = mp, attrs) do
    mp
    |> MegaPrompt.changeset(attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Canonical CRUD — Methodologies
  # ---------------------------------------------------------------------------

  def list_methodologies, do: Repo.all(Methodology)

  def get_methodology!(id), do: Repo.get!(Methodology, id)

  def get_methodology(id), do: Repo.get(Methodology, id)

  @doc "Delete a canonical methodology (control-plane only; tenant copies persist)."
  def delete_methodology(%Methodology{} = m), do: Repo.delete(m)

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

  def get_scenario(id), do: Repo.get(Scenario, id)

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

  @doc """
  Delete a canonical scenario from the control plane. Tenant copies already
  published (upserted by id) are NOT removed — publish only ever upserts — so this
  stops the scenario being offered/re-published centrally; existing tenant copies
  remain until separately cleaned up.
  """
  def delete_scenario(%Scenario{} = s), do: Repo.delete(s)

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

    # --- MegaPrompts ---
    # Skip by DOMAIN, not id: a tenant override is a new-id versioned row, so an
    # id-based skip would let the canonical active row collide with the tenant's
    # active override on the one-active-per-domain index (see
    # `publishable_mega_prompts/0`). Fresh tenants have no overrides, so this is
    # a no-op at first seed; it only matters if provision is re-run later.
    overridden_mega_prompt_domains =
      TenantRepo.all(from r in TenantMegaPrompt, where: r.is_overridden == true, select: r.domain)
      |> MapSet.new()

    mega_prompt_rows =
      Repo.all(MegaPrompt)
      |> Enum.reject(fn mp -> MapSet.member?(overridden_mega_prompt_domains, mp.domain) end)
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
        max_call_attempts_per_phase: settings.max_call_attempts_per_phase,
        max_context_tokens_warn: settings.max_context_tokens_warn,
        default_methodology_id: settings.default_methodology_id,
        is_overridden: false,
        updated_at: now
      }

      # On re-provision the row already exists. Replace ONLY the central-owned
      # columns — never the tenant-private CRM credentials (crm_provider, tokens,
      # domain) or the is_overridden flag — so re-provisioning can't wipe creds.
      # (On first provision there's no conflict, so the CRM columns take their
      # schema defaults.)
      TenantRepo.insert_all(TenantGlobalSettings, [settings_row],
        on_conflict: {:replace, central_owned_settings_columns()},
        conflict_target: :id
      )
    end

    :ok
  end

  # The GlobalSettings columns the control-plane owns and may overwrite on
  # publish/seed. Deliberately excludes the per-tenant CRM credential columns and
  # is_overridden so tenant-private data is never reset.
  defp central_owned_settings_columns do
    [
      :pre_call_offset_minutes,
      :post_call_offset_minutes,
      :retry_interval_minutes,
      :max_call_attempts_per_phase,
      :max_context_tokens_warn,
      :default_methodology_id,
      :updated_at
    ]
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
      publishable_mega_prompts(),
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
        max_call_attempts_per_phase: settings.max_call_attempts_per_phase,
        max_context_tokens_warn: settings.max_context_tokens_warn,
        default_methodology_id: settings.default_methodology_id,
        updated_at: now
      }

      TenantRepo.insert_all(TenantGlobalSettings, [row],
        on_conflict: {:replace, central_owned_settings_columns()},
        conflict_target: :id
      )
    end

    :ok
  end

  # Canonical mega-prompts to publish, EXCLUDING any whose domain the tenant has
  # locally overridden. MegaPrompts are versioned: a tenant edit is a NEW row
  # (new id) flagged is_overridden, while the canonical row keeps its own id. So
  # the id-based skip in `publish_table` can't protect them — re-publishing the
  # canonical row as active would collide with the tenant's active override on
  # the "one active version per domain" partial unique index and abort the whole
  # publish. Skipping by DOMAIN leaves a customized domain entirely tenant-owned.
  # (Must run with the tenant prefix pinned — it is, inside `do_publish`.)
  defp publishable_mega_prompts do
    overridden_domains =
      TenantRepo.all(from r in TenantMegaPrompt, where: r.is_overridden == true, select: r.domain)
      |> MapSet.new()

    Repo.all(MegaPrompt)
    |> Enum.reject(fn mp -> MapSet.member?(overridden_domains, mp.domain) end)
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
