defmodule Florina.Prompts do
  @moduledoc """
  Context for the Auto Prompt Assembler's versioned meta-prompts
  (`voice_megaprompt`) and the run audit log (`voice_generationrun`). Per-tenant.

  MegaPrompts are versioned: editing creates a NEW version; at most one active
  version per domain. `activate/1` flips the active version atomically.
  """
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.Prompts.{MegaPrompt, GenerationRun}

  # --- MegaPrompt ----------------------------------------------------------

  def list_by_domain(domain),
    do:
      TenantRepo.all(from m in MegaPrompt, where: m.domain == ^domain, order_by: [desc: m.version])

  def get_mega!(id), do: TenantRepo.get!(MegaPrompt, id)
  def get_mega(id), do: TenantRepo.get(MegaPrompt, id)

  @doc "The single active mega-prompt for a domain, or nil."
  def get_active(domain),
    do:
      TenantRepo.one(
        from m in MegaPrompt, where: m.domain == ^domain and m.is_active == true, limit: 1
      )

  @doc "Create the next version of a mega-prompt for its domain (auto-increments version)."
  def create_version(%{domain: domain} = attrs) do
    attrs = Map.put(attrs, :version, next_version(domain))
    %MegaPrompt{} |> MegaPrompt.changeset(attrs) |> TenantRepo.insert()
  end

  defp next_version(domain) do
    max = TenantRepo.one(from m in MegaPrompt, where: m.domain == ^domain, select: max(m.version))
    (max || 0) + 1
  end

  @doc "Make this version the single active one for its domain (deactivates siblings)."
  def activate(%MegaPrompt{} = mp) do
    TenantRepo.transaction(fn ->
      from(m in MegaPrompt,
        where: m.domain == ^mp.domain and m.id != ^mp.id and m.is_active == true
      )
      |> TenantRepo.update_all(set: [is_active: false])

      {:ok, updated} = mp |> MegaPrompt.changeset(%{is_active: true}) |> TenantRepo.update()
      updated
    end)
  end

  # --- GenerationRun (audit) ----------------------------------------------

  @doc "Record a generation-run audit row (sets created_at if absent)."
  def create_run(attrs) do
    attrs = Map.put_new(attrs, :created_at, now())
    %GenerationRun{} |> GenerationRun.changeset(attrs) |> TenantRepo.insert()
  end

  def list_runs_for_visit(visit_id),
    do:
      TenantRepo.all(
        from r in GenerationRun, where: r.visit_id == ^visit_id, order_by: [desc: r.created_at]
      )

  def list_runs_for_client(client_id),
    do:
      TenantRepo.all(
        from r in GenerationRun, where: r.client_id == ^client_id, order_by: [desc: r.created_at]
      )

  def recent_runs(limit \\ 50),
    do: TenantRepo.all(from r in GenerationRun, order_by: [desc: r.created_at], limit: ^limit)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
