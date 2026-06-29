defmodule Florina.Workers.CalendarSyncAgent do
  @moduledoc """
  Per-AGENT calendar sync + visit detection (one job = one agent).

  Enqueued by `CalendarSync` (the per-tenant fan-out), one job per sales agent.
  Splitting the old per-tenant serial loop into one job per agent means agents
  sync in parallel across the `:sync` queue, a single agent's failure retries in
  isolation (Oban backoff) instead of being buried in a tenant-wide log line, and
  each agent's result is independently observable.

  For the agent's stored calendar credentials:

    1. Lists calendar events (yesterday → +14 days) via the provider.
    2. Classifies each event: a meeting with an attendee outside the tenant's
       own `allowed_email_domains` is a CLIENT meeting; internal-only meetings
       are ignored. A known client domain is linked; an unknown external domain
       auto-creates a `Client`. (If the tenant has no domains configured, falls
       back to the conservative known-client-only match.)
    3. Creates a `Visit` for client meetings (or updates time/title if it
       already exists); resolves a CRM deal for new visits.
    4. Reconciles cancellations/deletions (retires vanished future meetings).

  ## Tenant context

  Like every per-tenant worker, this pins BOTH `:tenant_prefix` (which schema)
  and `:tenant_repo` (which connection pool) via `Workers.Tenant.pin_active/1`
  before touching any data — the fan-out spawns a fresh job process per agent,
  so each must re-establish tenant context (same fail-closed rule as everywhere).

  ## DB-connection safety (why fan-out is safe here)

  No database connection is held across the provider HTTP call: `list_events`
  (and any token refresh inside it) completes and returns before the per-event
  `TenantRepo` writes run, and those writes each check a connection out only
  briefly. So multiplying these jobs does not multiply long-held connections.

  Args required: `tenant_slug`, `agent_id`.
  """
  # Unique per (tenant, agent) within a window shorter than the 5-min cadence:
  # dedups a double-enqueue (scheduler/fan-out retry, or a slow sync overlapping
  # the next tick) without swallowing the next cycle — and, critically, stops the
  # same agent being synced twice concurrently against the calendar API.
  use Oban.Worker,
    queue: :sync,
    max_attempts: 3,
    unique: [period: 120, keys: [:tenant_slug, :agent_id]]

  require Logger

  import Ecto.Query

  alias Florina.TenantRepo
  alias Florina.Accounts
  alias Florina.Accounts.User
  alias Florina.OAuth
  alias Florina.Integrations.Provider
  alias Florina.CalendarEvents
  alias Florina.Clients
  alias Florina.Visits
  alias Florina.Visits.Visit
  alias Florina.Services.VisitPipeline
  alias Florina.Workers.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug, "agent_id" => agent_id}}) do
    with :ok <- Tenant.pin_active(slug) do
      case Accounts.get_user(agent_id) do
        nil ->
          # Agent removed between fan-out and execution — nothing to do.
          Logger.info("[CalendarSyncAgent] tenant=#{slug} agent=#{agent_id} not found — skipping")
          :ok

        %User{active: false} ->
          # Deactivated after fan-out (jobs are jittered, so there's a real gap
          # between enqueue and run) — don't sync a disabled agent's calendar.
          Logger.info("[CalendarSyncAgent] tenant=#{slug} agent=#{agent_id} inactive — skipping")
          :ok

        agent ->
          {window_start, window_end} = sync_window(DateTime.utc_now())
          allowed = internal_domains(slug)

          # No outer rescue: with one job per agent there's no sibling loop to
          # protect, so an unexpected crash should FAIL this agent's job and let
          # Oban retry it in isolation. Soft per-event/per-credential errors are
          # still caught below and recorded, so they don't fail the whole job.
          result = sync_agent(agent, window_start, window_end, allowed)

          Logger.info(
            "[CalendarSyncAgent] tenant=#{slug} agent=#{agent.username} " <>
              "created=#{result.created} updated=#{result.updated} skipped=#{result.skipped} " <>
              "cancelled=#{result.cancelled} errors=#{length(result.errors)}"
          )

          :ok
      end
    else
      :skip ->
        Logger.info("[CalendarSyncAgent] tenant=#{slug} not active — skipping")
        :ok
    end
  end

  # Sync window: from start of yesterday (UTC) through +14 days ahead, so
  # meetings created for upcoming days — and same-day meetings in tenants whose
  # local day is ahead of/behind UTC — are picked up well before their call
  # offsets fire.
  defp sync_window(now) do
    start = now |> DateTime.add(-1 * 86_400, :second) |> beginning_of_day()
    finish = now |> DateTime.add(14 * 86_400, :second) |> end_of_day()
    {start, finish}
  end

  defp beginning_of_day(dt), do: %{dt | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
  defp end_of_day(dt), do: %{dt | hour: 23, minute: 59, second: 59, microsecond: {0, 0}}

  # The tenant's own email domains (the SSO admit-list), lowercased. Attendees on
  # these domains are colleagues; an attendee on any other domain makes the
  # meeting a client meeting. Empty when unconfigured.
  defp internal_domains(slug) do
    case Florina.Tenants.get_by_slug(slug) do
      %{allowed_email_domains: domains} when is_list(domains) ->
        Enum.map(domains, &String.downcase/1)

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Per-agent sync
  # ---------------------------------------------------------------------------

  defp sync_agent(agent, today_start, today_end, allowed) do
    acc = %{created: 0, updated: 0, skipped: 0, cancelled: 0, errors: []}

    case OAuth.list_calendar_credentials_for_user(agent.id) do
      [] ->
        Logger.debug(
          "[CalendarSyncAgent] agent=#{agent.username} has no calendar credential — skip"
        )

        acc

      creds ->
        # An agent may connect both Google and Microsoft — sync each provider and
        # accumulate the counts across them.
        Enum.reduce(creds, acc, fn cred, acc ->
          sync_agent_credential(agent, cred, today_start, today_end, allowed, acc)
        end)
    end
  end

  defp sync_agent_credential(agent, cred, today_start, today_end, allowed, acc) do
    case Provider.for_credential(cred).list_events(cred, today_start, today_end) do
      {:ok, events} ->
        Enum.each(events, fn ev ->
          case CalendarEvents.upsert_event(agent.id, cred.provider, ev) do
            {:ok, _} ->
              :ok

            {:error, cs} ->
              Logger.warning("[CalendarSyncAgent] event upsert failed: #{inspect(cs.errors)}")
          end
        end)

        acc =
          Enum.reduce(events, acc, fn event, a ->
            case process_event(agent, cred.provider, allowed, event) do
              {:created, _} -> %{a | created: a.created + 1}
              {:updated, _} -> %{a | updated: a.updated + 1}
              :skipped -> %{a | skipped: a.skipped + 1}
              {:error, msg} -> %{a | errors: [msg | a.errors]}
            end
          end)

        reconcile_cancelled(agent.id, cred.provider, today_start, today_end, events, acc)

      {:error, reason} ->
        msg =
          "CalendarSyncAgent agent=#{agent.username} provider=#{cred.provider} fetch error: #{inspect(reason)}"

        Logger.error("[CalendarSyncAgent] #{msg}")
        %{acc | errors: [msg | acc.errors]}
    end
  rescue
    # One malformed event (e.g. a bad upsert or reconcile) must not abort the
    # whole credential's sync — log it, record it in `errors`, and move on.
    e ->
      msg =
        "CalendarSyncAgent agent=#{agent.username} provider=#{cred.provider} crashed: #{Exception.message(e)}"

      Logger.error("[CalendarSyncAgent] #{msg}")
      %{acc | errors: [msg | acc.errors]}
  end

  # ---------------------------------------------------------------------------
  # Per-event processing
  # ---------------------------------------------------------------------------

  defp process_event(
         agent,
         provider,
         allowed_domains,
         %{id: event_id, attendees: attendees} = event
       ) do
    cond do
      Map.get(event, :status) == "cancelled" ->
        cancel_existing_visit(event_id, agent.id, provider)

      true ->
        case classify(attendees, allowed_domains) do
          :internal ->
            :skipped

          {:error, reason} ->
            {:error, "event=#{event_id} client resolution failed: #{inspect(reason)}"}

          {:client_meeting, client} ->
            case find_existing_visit(event_id, agent.id, provider) do
              %Visit{} = existing ->
                update_visit_if_changed(existing, event)

              nil ->
                create_visit(agent, provider, client, event)
            end
        end
    end
  rescue
    e ->
      {:error, "event=#{Map.get(event, :id, "?")} error: #{Exception.message(e)}"}
  end

  # A cancelled meeting must not spawn a visit. If one already exists for this
  # event and hasn't completed, retire it to :CANCELLED so the call scheduler
  # (which only acts on :PLANNED / :PRE_CALL_DONE / :IN_PROGRESS) stops dialing.
  defp cancel_existing_visit(event_id, agent_id, provider) do
    case find_existing_visit(event_id, agent_id, provider) do
      %Visit{status: status} = existing
      when status in [:PLANNED, :PRE_CALL_DONE, :IN_PROGRESS] ->
        case Visits.update(existing, %{status: :CANCELLED}) do
          {:ok, _v} -> :skipped
          {:error, cs} -> {:error, "cancel failed: #{inspect(cs.errors)}"}
        end

      _ ->
        :skipped
    end
  end

  # Provider-agnostic safety net for cancellations/deletions. Google omits
  # cancelled events from the list entirely (we don't request deleted ones), so
  # a cancelled meeting simply vanishes rather than arriving with status
  # "cancelled". Any active visit in the synced window whose calendar event is no
  # longer returned was cancelled or deleted — retire it to :CANCELLED so the
  # scheduler stops dialing. Scoped to FUTURE visits only, so a transient/empty
  # fetch can't retroactively cancel meetings that already happened.
  defp reconcile_cancelled(agent_id, provider, _window_start, window_end, events, acc) do
    now = DateTime.utc_now()
    present_ids = events |> Enum.map(& &1.id) |> MapSet.new()

    stale =
      from(v in Visit,
        where:
          v.agent_id == ^agent_id and v.provider == ^provider and
            not is_nil(v.calendar_event_id) and
            v.status in ^[:PLANNED, :PRE_CALL_DONE, :IN_PROGRESS] and
            v.start_time >= ^now and v.start_time <= ^window_end
      )
      |> TenantRepo.all()
      |> Enum.reject(fn v -> MapSet.member?(present_ids, v.calendar_event_id) end)

    Enum.reduce(stale, acc, fn v, a ->
      case Visits.update(v, %{status: :CANCELLED}) do
        {:ok, _} ->
          Logger.info(
            "[CalendarSyncAgent] retired visit=#{v.id} — event #{v.calendar_event_id} no longer on #{provider} calendar"
          )

          %{a | cancelled: a.cancelled + 1}

        {:error, cs} ->
          %{a | errors: ["reconcile failed visit=#{v.id}: #{inspect(cs.errors)}" | a.errors]}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Client-meeting classification
  #
  # A meeting is a client meeting iff an attendee is on a domain that is NOT one
  # of the tenant's own (`allowed_email_domains`). A known client domain is
  # linked; an unknown external domain auto-creates a client. Internal-only
  # meetings don't become visits. When the tenant has no domains configured we
  # can't tell internal from external, so we fall back to the conservative
  # known-client-only match (no auto-create).
  # ---------------------------------------------------------------------------

  defp classify(attendees, allowed_domains) do
    domains =
      attendees
      |> Enum.map(&VisitPipeline.extract_domain_from_email/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    external = Enum.reject(domains, &(&1 in allowed_domains))

    cond do
      allowed_domains == [] ->
        case Enum.find_value(domains, &Clients.get_by_domain/1) do
          nil -> :internal
          client -> {:client_meeting, client}
        end

      external == [] ->
        :internal

      true ->
        case Enum.find_value(external, &Clients.get_by_domain/1) do
          nil ->
            case ensure_client(List.first(external)) do
              nil -> {:error, :client_create_failed}
              client -> {:client_meeting, client}
            end

          client ->
            {:client_meeting, client}
        end
    end
  end

  # Find-or-create a client for an unknown external domain. crm_id is a stable
  # "auto:<domain>" so re-syncs reuse the same row rather than duplicating.
  defp ensure_client(domain) do
    case Clients.get_by_domain(domain) do
      nil ->
        case Clients.create(%{crm_id: "auto:" <> domain, name: domain, domain: domain}) do
          {:ok, client} -> client
          # Lost a race / unique conflict — fetch whatever now exists.
          {:error, _cs} -> Clients.get_by_domain(domain)
        end

      client ->
        client
    end
  end

  # ---------------------------------------------------------------------------
  # Visit helpers
  # ---------------------------------------------------------------------------

  defp find_existing_visit(event_id, agent_id, provider) do
    from(v in Visit,
      where:
        v.calendar_event_id == ^event_id and v.agent_id == ^agent_id and
          v.provider == ^provider
    )
    |> TenantRepo.one()
  end

  defp update_visit_if_changed(%Visit{} = existing, event) do
    changes =
      %{}
      |> maybe_change(existing.start_time, event.start_time, :start_time)
      |> maybe_change(existing.end_time, event.end_time, :end_time)
      |> maybe_change(existing.title, event.title, :title)

    if map_size(changes) > 0 do
      case Visits.update(existing, changes) do
        {:ok, v} -> {:updated, v}
        {:error, cs} -> {:error, "update failed: #{inspect(cs.errors)}"}
      end
    else
      :skipped
    end
  end

  defp create_visit(agent, provider, client, event) do
    crm_deal_id = resolve_crm_deal(client)

    attrs = %{
      agent_id: agent.id,
      client_id: client.id,
      calendar_event_id: event.id,
      provider: provider,
      title: event.title,
      start_time: event.start_time,
      end_time: event.end_time,
      attendees: Enum.map(event.attendees, &%{"email" => &1}),
      crm_deal_id: crm_deal_id,
      status: :PLANNED
    }

    case Visits.create(attrs) do
      {:ok, v} ->
        Logger.info("[CalendarSyncAgent] created visit=#{v.id} client=#{client.name}")
        {:created, v}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if Keyword.has_key?(errors, :calendar_event_id) do
          # Lost a race with a concurrent sync — the unique index rejected the
          # duplicate. The visit already exists, so treat this as a no-op.
          Logger.debug("[CalendarSyncAgent] duplicate visit for event=#{event.id} — skipping")
          :skipped
        else
          {:error, "create failed: #{inspect(cs.errors)}"}
        end
    end
  end

  # Resolves the most recent open CRM deal for the given client.
  # Called only when CREATING a new visit — not on re-syncs of existing visits —
  # to avoid hammering the CRM on every calendar sync cycle.
  # Returns a deal ID string, or nil if none found / any error occurs.
  defp resolve_crm_deal(client) do
    if is_nil(client.crm_id) or client.crm_id == "" do
      nil
    else
      case Florina.Integrations.CRM.get_organization_deals(client.crm_id) do
        {:ok, deals} when is_list(deals) ->
          # Prefer an open deal; fall back to the most-recent deal of any status.
          open_deal = Enum.find(deals, fn d -> d["status"] == "open" end)
          best = open_deal || List.first(deals)

          case best do
            %{"id" => deal_id} -> to_string(deal_id)
            _ -> nil
          end

        {:error, reason} ->
          Logger.warning(
            "[CalendarSyncAgent] resolve_crm_deal failed for client=#{client.name}: #{inspect(reason)}"
          )

          nil

        _ ->
          nil
      end
    end
  rescue
    e ->
      Logger.warning("[CalendarSyncAgent] resolve_crm_deal error: #{Exception.message(e)}")
      nil
  end

  defp maybe_change(map, old, new, key) when old != new, do: Map.put(map, key, new)
  defp maybe_change(map, _old, _new, _key), do: map
end
