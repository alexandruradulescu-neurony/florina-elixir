defmodule Florina.Visits do
  @moduledoc """
  Context for the `Visit` entity — the central scheduling/call record.

  Mirrors Django's visit selectors (`get_agent_visits`, `get_upcoming_visits_for_agent`,
  etc.) and the visit CRUD views. The `effective_methodology/1` function replicates
  `Visit.get_effective_methodology()` from Django models.py:

      visit override → agent default → GlobalSettings default

  All queries hit `TenantRepo` (the per-tenant dynamic repo).
  """

  import Ecto.Query, only: [from: 2, order_by: 2, where: 2, preload: 2, limit: 2]
  alias Florina.TenantRepo
  alias Florina.Visits.Visit
  alias Florina.Settings.GlobalSettings

  # ---------------------------------------------------------------------------
  # Standard association preload used on most "detail" fetches
  # ---------------------------------------------------------------------------

  @full_preloads [:agent, :client, :methodology, :scenario]

  # ---------------------------------------------------------------------------
  # Basic get / fetch
  # ---------------------------------------------------------------------------

  @doc """
  Gets a visit by ID. Raises `Ecto.NoResultsError` if not found.
  No preloads — use `get_with_associations/1` when you need related records.
  """
  def get!(id) do
    TenantRepo.get!(Visit, id)
  end

  @doc """
  Gets a visit by ID with agent, client, methodology, scenario, and
  call_attempts preloaded.

  Returns `nil` if not found.

  Mirrors Django's `get_visit_detail` / visit detail view queries, which
  do `.select_related("agent", "client", "methodology")` and
  `.prefetch_related("call_attempts")`.
  """
  def get_with_associations(id) do
    Visit
    |> preload([:agent, :client, :methodology, :scenario, :call_attempts])
    |> TenantRepo.get(id)
  end

  # ---------------------------------------------------------------------------
  # List / filter queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns all visits for a specific agent ordered by most-recent first.

  Mirrors Django's `get_agent_visits(agent, limit=20)`.
  Default limit: 20, matching Django. Pass `nil` for no limit.
  """
  def list_for_agent(agent_id, limit \\ 20) do
    q =
      Visit
      |> where(agent_id: ^agent_id)
      |> preload(^@full_preloads)
      |> order_by(desc: :start_time)

    if limit do
      q |> limit(^limit) |> TenantRepo.all()
    else
      TenantRepo.all(q)
    end
  end

  @doc """
  Returns all visits for a specific client, most-recent first.

  Mirrors Django's client detail view: `Visit.objects.filter(client=client)
  .select_related("agent","methodology").order_by("-start_time")`.
  """
  def list_for_client(client_id) do
    Visit
    |> where(client_id: ^client_id)
    |> preload([:agent, :methodology, :scenario])
    |> order_by(desc: :start_time)
    |> TenantRepo.all()
  end

  @doc """
  Returns upcoming visits (start_time in the future), ordered ascending.

  Optionally accepts an agent_id to scope to a single agent. Matches Django's
  `get_upcoming_visits_for_agent(agent, limit=10)` when agent_id is given.
  Default limit: 10.
  """
  def list_upcoming(agent_id \\ nil, limit \\ 10) do
    now = DateTime.utc_now()

    q =
      from v in Visit,
        where: v.start_time > ^now,
        preload: [:agent, :client, :methodology, :scenario],
        order_by: [asc: :start_time]

    q =
      if agent_id do
        from v in q, where: v.agent_id == ^agent_id
      else
        q
      end

    q |> limit(^limit) |> TenantRepo.all()
  end

  @doc """
  Returns all visits with the given status atom, ordered by start_time desc.

  Status atoms match `Florina.Enums.visit_status_values/0` keys:
  `:PLANNED`, `:PRE_CALL_DONE`, `:IN_PROGRESS`, `:POST_CALL_DONE`, `:COMPLETE`.
  """
  def list_by_status(status) do
    Visit
    |> where(status: ^status)
    |> preload(^@full_preloads)
    |> order_by(desc: :start_time)
    |> TenantRepo.all()
  end

  @doc """
  All visits, newest first, with full associations. Manager-only view (no agent
  scope) — used by the manager meetings list.
  """
  def list_all(limit \\ 100) do
    Visit
    |> preload(^@full_preloads)
    |> order_by(desc: :start_time)
    |> limit(^limit)
    |> TenantRepo.all()
  end

  @doc """
  Visits whose `start_time` falls on `date` (UTC), every agent, ascending, with
  agent + client preloaded. Powers the manager dashboard's "today" list.
  """
  def list_for_day(%Date{} = date) do
    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

    from(v in Visit,
      where: v.start_time >= ^day_start and v.start_time <= ^day_end,
      preload: [:agent, :client],
      order_by: [asc: :start_time]
    )
    |> TenantRepo.all()
  end

  @doc """
  Active visits whose `start_time` falls within `[from_dt, to_dt]`, every agent,
  ascending, with agent + client preloaded. Cancelled visits are excluded.
  Powers the manager calendar (client meetings only, not raw calendar events).
  """
  def list_in_range(%DateTime{} = from_dt, %DateTime{} = to_dt) do
    from(v in Visit,
      where: v.start_time >= ^from_dt and v.start_time <= ^to_dt and v.status != :CANCELLED,
      preload: [:agent, :client],
      order_by: [asc: :start_time]
    )
    |> TenantRepo.all()
  end

  @doc """
  One agent's visits on `date` (UTC), ascending, with client preloaded. Powers
  the agent's "my meetings today" view — scoped to that agent only.
  """
  def list_for_agent_day(agent_id, %Date{} = date) do
    day_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    day_end = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

    from(v in Visit,
      where: v.agent_id == ^agent_id and v.start_time >= ^day_start and v.start_time <= ^day_end,
      preload: [:client],
      order_by: [asc: :start_time]
    )
    |> TenantRepo.all()
  end

  # ---------------------------------------------------------------------------
  # Effective-methodology lookup
  # ---------------------------------------------------------------------------

  @doc """
  Resolves the effective methodology for a visit following the three-level
  fallback used by Django's `Visit.get_effective_methodology()`:

    1. Visit-level override (`visit.methodology_id` present)
    2. Agent default (`visit.agent.default_methodology_id` present)
    3. System default (`GlobalSettings.default_methodology_id`)

  Returns a `%Florina.Methodologies.Methodology{}` or `nil`.

  The visit struct **must** have its `:agent` association loaded (e.g. via
  `get_with_associations/1` or `TenantRepo.preload(visit, agent: :default_methodology)`).
  The function preloads `agent.default_methodology` itself if it detects the
  association is not yet loaded.
  """
  def effective_methodology(%Visit{} = visit) do
    # 1. Visit-level override
    if visit.methodology_id do
      case TenantRepo.get(Florina.Methodologies.Methodology, visit.methodology_id) do
        nil -> resolve_agent_or_system_default(visit)
        m -> m
      end
    else
      resolve_agent_or_system_default(visit)
    end
  end

  defp resolve_agent_or_system_default(%Visit{agent: %Ecto.Association.NotLoaded{}} = visit) do
    visit = TenantRepo.preload(visit, agent: :default_methodology)
    resolve_agent_or_system_default(visit)
  end

  defp resolve_agent_or_system_default(%Visit{agent: agent}) do
    # 2. Agent default
    agent_methodology =
      case agent do
        %{default_methodology_id: nil} ->
          nil

        %{default_methodology: %Ecto.Association.NotLoaded{}, default_methodology_id: id}
        when not is_nil(id) ->
          TenantRepo.get(Florina.Methodologies.Methodology, id)

        %{default_methodology: m} ->
          m

        _ ->
          nil
      end

    if agent_methodology do
      agent_methodology
    else
      # 3. System default
      settings = GlobalSettings.load()

      case settings do
        %{default_methodology_id: nil} ->
          nil

        %{default_methodology: %Ecto.Association.NotLoaded{}, default_methodology_id: id}
        when not is_nil(id) ->
          TenantRepo.get(Florina.Methodologies.Methodology, id)

        %{default_methodology: m} ->
          m

        _ ->
          nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a visit.

  Returns `{:ok, visit}` or `{:error, changeset}`.
  """
  def create(attrs \\ %{}) do
    %Visit{}
    |> Visit.changeset(attrs)
    |> TenantRepo.insert()
  end

  @doc """
  Updates a visit.

  Returns `{:ok, visit}` or `{:error, changeset}`.
  """
  def update(%Visit{} = visit, attrs) do
    visit
    |> Visit.changeset(attrs)
    |> TenantRepo.update()
  end

  @doc """
  Deletes a visit.

  Returns `{:ok, visit}` or `{:error, changeset}`.
  """
  def delete(%Visit{} = visit) do
    TenantRepo.delete(visit)
  end
end
