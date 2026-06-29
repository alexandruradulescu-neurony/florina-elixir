defmodule Florina.Workers.CalendarSync do
  @moduledoc """
  Per-tenant calendar-sync FAN-OUT.

  Enqueued by `CalendarSyncScheduler` (one per active tenant). Lists the tenant's
  sales agents and enqueues one `CalendarSyncAgent` job per agent, so each agent's
  calendar sync runs as an independent job — they parallelise across the `:sync`
  queue, retry in isolation, and are individually observable, instead of one big
  job syncing every agent one-after-another.

  ## Jitter (why it ships with the fan-out)

  Fanning out is exactly what creates a burst: at 100 tenants × 20 agents the top
  of every 5-minute window would otherwise enqueue ~2,000 agent jobs at once, and
  burst (not average) volume is what trips calendar-API rate limits. Each agent
  job is therefore scheduled at a random delay within
  `:calendar_sync_jitter_seconds` (default 120s in prod; 0 in test for
  determinism), spreading the load into a flat line under the window.

  The remaining lever — capping how many agent jobs run at once — is the `:sync`
  queue's concurrency, tuned in config when tenant count actually grows. This
  worker only shapes *when* jobs start, not *how many* run concurrently.

  Args required: `tenant_slug`.
  """
  use Oban.Worker,
    queue: :scheduler,
    max_attempts: 3,
    unique: [period: 120, keys: [:tenant_slug]]

  require Logger

  alias Florina.Accounts
  alias Florina.Workers.{CalendarSyncAgent, Tenant}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug}}) do
    with :ok <- Tenant.pin_active(slug) do
      agents = Accounts.list_active_agents()
      Logger.info("[CalendarSync] tenant=#{slug} fanning out to #{length(agents)} agent(s)")
      jitter = jitter_seconds()

      for agent <- agents do
        %{tenant_slug: slug, agent_id: agent.id}
        |> CalendarSyncAgent.new(scheduling_opts(jitter))
        |> Oban.insert()
      end

      :ok
    else
      :skip ->
        Logger.info("[CalendarSync] tenant=#{slug} not active — skipping")
        :ok
    end
  end

  # Spread each agent job across [0, jitter) seconds so a whole tenant's agents
  # (and, at scale, every tenant's agents) don't all hit the calendar API at the
  # same instant. With jitter 0 (tests) jobs are enqueued for immediate run.
  defp scheduling_opts(0), do: []
  defp scheduling_opts(jitter), do: [schedule_in: :rand.uniform(jitter)]

  defp jitter_seconds, do: Application.get_env(:florina, :calendar_sync_jitter_seconds, 120)
end
