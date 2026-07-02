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
  alias Florina.Strings

  # --- MegaPrompt ----------------------------------------------------------

  def list_by_domain(domain),
    do:
      TenantRepo.all(
        from m in MegaPrompt, where: m.domain == ^domain, order_by: [desc: m.version]
      )

  def get_mega!(id), do: TenantRepo.get!(MegaPrompt, id)

  # Tolerate a non-integer id (a tampered/garbage phx-value) with nil rather than
  # an Ecto.Query.CastError that crashes the LiveView — matches get_run/1.
  def get_mega(id) when is_integer(id), do: TenantRepo.get(MegaPrompt, id)

  def get_mega(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> TenantRepo.get(MegaPrompt, int)
      _ -> nil
    end
  end

  def get_mega(_), do: nil

  @doc "The single active mega-prompt for a domain, or nil."
  def get_active(domain),
    do:
      TenantRepo.one(
        from m in MegaPrompt, where: m.domain == ^domain and m.is_active == true, limit: 1
      )

  @doc """
  Create the next version of a mega-prompt for its domain (auto-increments version).

  Automatically sets `is_overridden: true` so publish won't overwrite this
  tenant-local version. A fuller id-space partition (to avoid id collisions with
  canonical rows) is deferred as future work.
  """
  def create_version(%{domain: domain} = attrs) do
    attrs =
      attrs
      |> Map.put(:version, next_version(domain))
      |> Map.put(:is_overridden, true)

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

      case mp |> MegaPrompt.changeset(%{is_active: true}) |> TenantRepo.update() do
        {:ok, updated} -> updated
        # A concurrent activate can trip the one-active-per-domain index; roll
        # back cleanly instead of crashing with a MatchError.
        {:error, changeset} -> TenantRepo.rollback(changeset)
      end
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

  @doc """
  Paginated, filtered audit list for the Generation Runs screen. `filters` is a
  plain map (string keys, as from a form):

    * `"domain"`  — one of `Enums.mega_prompt_domain_values/0` strings
    * `"outcome"` — `"success"` | `"failures"`

  Returns lightweight display maps (newest first). The encrypted PII fields
  (context bundle, Claude request/response, etc.) are deliberately NOT selected
  here — listing shouldn't decrypt them; that happens only on the detail page
  (`get_run/1`), where the read is audited.
  """
  def list_runs(filters \\ %{}, page \\ 1, per_page \\ 50) do
    offset = (max(page, 1) - 1) * per_page

    runs_query(filters)
    |> order_by(desc: :created_at)
    |> limit(^per_page)
    |> offset(^offset)
    |> select([r], %{
      id: r.id,
      created_at: r.created_at,
      domain: r.domain,
      triggered_by: r.triggered_by,
      success: r.success,
      input_tokens: r.input_tokens,
      output_tokens: r.output_tokens,
      visit_id: r.visit_id,
      client_id: r.client_id
    })
    |> TenantRepo.all()
  end

  @doc "Total count matching `filters` — for pagination."
  def count_runs(filters \\ %{}) do
    runs_query(filters) |> TenantRepo.aggregate(:count)
  end

  @doc "One run with all associations, or nil. Encrypted fields decrypt on read."
  def get_run(id) when is_integer(id) do
    case TenantRepo.get(GenerationRun, id) do
      nil -> nil
      run -> TenantRepo.preload(run, [:visit, :client, :mega_prompt, :created_by])
    end
  end

  # Tolerate a non-integer id (e.g. a hand-edited URL) — return nil instead of
  # raising Ecto.Query.CastError against the bigint primary key.
  def get_run(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> get_run(int)
      _ -> nil
    end
  end

  def get_run(_), do: nil

  defp runs_query(filters) do
    GenerationRun
    |> filter_domain(Strings.blank_to_nil(filters["domain"]))
    |> filter_outcome(Strings.blank_to_nil(filters["outcome"]))
  end

  defp filter_domain(query, nil), do: query

  defp filter_domain(query, domain) do
    # `domain` comes straight from a URL/form param. An unknown value would crash
    # `to_existing_atom`, so an unrecognised filter just drops to "no filter".
    case safe_existing_atom(domain) do
      nil -> query
      atom -> from(r in query, where: r.domain == ^atom)
    end
  end

  defp safe_existing_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp filter_outcome(query, "success"), do: from(r in query, where: r.success == true)
  defp filter_outcome(query, "failures"), do: from(r in query, where: r.success == false)
  defp filter_outcome(query, _), do: query

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
