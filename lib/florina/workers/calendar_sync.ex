defmodule Florina.Workers.CalendarSync do
  @moduledoc """
  Per-tenant calendar sync + visit detection.

  Enqueued by `CalendarSyncScheduler`. For each sales agent with stored
  Google OAuth credentials:

    1. Lists today's calendar events via the configured calendar provider.
    2. For each event, tries to match attendee email domains against known
       `Client` records in the tenant DB.
    3. If a match is found: creates a new `Visit` (or updates times if the
       event already has a visit).
    4. Resolves a CRM deal from Pipedrive for new visits.

  Mirrors Django's `detect_visits_for_agent` / `sync_all_user_calendars`
  in `tasks.py` and `visit_pipeline.py`.

  Deferred from Django (not needed for MVP correctness):
  - Methodology auto-assignment on new visits (agent default / system default
    fallback). The visit is created with no methodology; the UI/assembler
    resolves it at assembly time via `Visits.effective_methodology/1`.
  - CRM deal resolution for existing (already-created) visits — not worth
    calling Pipedrive every sync cycle for visits that already have a deal.
  - Error logging to `voice_activitylog` — the Elixir port logs via Logger.

  Args required: `tenant_slug`.
  """
  use Oban.Worker, queue: :sync, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Florina.TenantRepo
  alias Florina.Accounts
  alias Florina.OAuth
  alias Florina.Integrations.Provider
  alias Florina.CalendarEvents
  alias Florina.Clients
  alias Florina.Visits
  alias Florina.Visits.Visit
  alias Florina.Services.VisitPipeline
  alias Florina.Workers.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug}}) do
    with :ok <- Tenant.pin_active(slug) do
      agents = Accounts.list_agents()
      {window_start, window_end} = sync_window(DateTime.utc_now())

      results =
        Enum.map(agents, fn agent ->
          {agent.username, sync_agent(agent, window_start, window_end)}
        end)

      total_created = results |> Enum.map(fn {_, r} -> r.created end) |> Enum.sum()
      total_updated = results |> Enum.map(fn {_, r} -> r.updated end) |> Enum.sum()
      total_skipped = results |> Enum.map(fn {_, r} -> r.skipped end) |> Enum.sum()
      total_errors = results |> Enum.flat_map(fn {_, r} -> r.errors end)

      Logger.info(
        "[CalendarSync] tenant=#{slug} created=#{total_created} updated=#{total_updated} " <>
          "skipped=#{total_skipped} errors=#{length(total_errors)}"
      )

      :ok
    else
      :skip ->
        Logger.info("[CalendarSync] tenant=#{slug} not active — skipping")
        :ok
    end
  end

  # Sync window: from start of yesterday (UTC) through +14 days ahead, so
  # meetings created for upcoming days — and same-day meetings in tenants whose
  # local day is ahead of/behind UTC — are picked up well before their call
  # offsets fire. (Was previously only the current UTC day, which could miss
  # meetings near the UTC midnight boundary or scheduled further out.)
  defp sync_window(now) do
    start = now |> DateTime.add(-1 * 86_400, :second) |> beginning_of_day()
    finish = now |> DateTime.add(14 * 86_400, :second) |> end_of_day()
    {start, finish}
  end

  defp beginning_of_day(dt), do: %{dt | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
  defp end_of_day(dt), do: %{dt | hour: 23, minute: 59, second: 59, microsecond: {0, 0}}

  # ---------------------------------------------------------------------------
  # Per-agent sync
  # ---------------------------------------------------------------------------

  defp sync_agent(agent, today_start, today_end) do
    acc = %{created: 0, updated: 0, skipped: 0, errors: []}

    case OAuth.list_calendar_credentials_for_user(agent.id) do
      [] ->
        Logger.debug("[CalendarSync] agent=#{agent.username} has no calendar credential — skip")
        acc

      creds ->
        # An agent may connect both Google and Microsoft — sync each provider and
        # accumulate the counts across them.
        Enum.reduce(creds, acc, fn cred, acc ->
          sync_agent_credential(agent, cred, today_start, today_end, acc)
        end)
    end
  end

  defp sync_agent_credential(agent, cred, today_start, today_end, acc) do
    case Provider.for_credential(cred).list_events(cred, today_start, today_end) do
      {:ok, events} ->
        Enum.each(events, fn ev ->
          case CalendarEvents.upsert_event(agent.id, cred.provider, ev) do
            {:ok, _} ->
              :ok

            {:error, cs} ->
              Logger.warning("[CalendarSync] event upsert failed: #{inspect(cs.errors)}")
          end
        end)

        Enum.reduce(events, acc, fn event, a ->
          case process_event(agent, cred.provider, event) do
            {:created, _} -> %{a | created: a.created + 1}
            {:updated, _} -> %{a | updated: a.updated + 1}
            :skipped -> %{a | skipped: a.skipped + 1}
            {:error, msg} -> %{a | errors: [msg | a.errors]}
          end
        end)

      {:error, reason} ->
        msg =
          "CalendarSync agent=#{agent.username} provider=#{cred.provider} fetch error: #{inspect(reason)}"

        Logger.error("[CalendarSync] #{msg}")
        %{acc | errors: [msg | acc.errors]}
    end
  end

  # ---------------------------------------------------------------------------
  # Per-event processing
  # ---------------------------------------------------------------------------

  defp process_event(agent, provider, %{id: event_id, attendees: attendees} = event) do
    cond do
      Map.get(event, :status) == "cancelled" ->
        cancel_existing_visit(event_id, agent.id, provider)

      true ->
        case match_client_by_attendees(attendees) do
          nil ->
            :skipped

          client ->
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
  # event and hasn't completed, retire it to COMPLETE so the call scheduler
  # (which only dials :PLANNED) stops — there is no dedicated CANCELLED status.
  defp cancel_existing_visit(event_id, agent_id, provider) do
    case find_existing_visit(event_id, agent_id, provider) do
      %Visit{status: status} = existing
      when status in [:PLANNED, :PRE_CALL_DONE, :IN_PROGRESS] ->
        case Visits.update(existing, %{status: :COMPLETE}) do
          {:ok, _v} -> :skipped
          {:error, cs} -> {:error, "cancel failed: #{inspect(cs.errors)}"}
        end

      _ ->
        :skipped
    end
  end

  # ---------------------------------------------------------------------------
  # Client matching by attendee email domain
  # ---------------------------------------------------------------------------

  defp match_client_by_attendees(attendees) do
    attendees
    |> Enum.uniq()
    |> Enum.find_value(fn email ->
      domain = VisitPipeline.extract_domain_from_email(email)

      if domain do
        Clients.get_by_domain(domain)
      end
    end)
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
        Logger.info("[CalendarSync] created visit=#{v.id} client=#{client.name}")
        {:created, v}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if Keyword.has_key?(errors, :calendar_event_id) do
          # Lost a race with a concurrent sync — the unique index rejected the
          # duplicate. The visit already exists, so treat this as a no-op.
          Logger.debug("[CalendarSync] duplicate visit for event=#{event.id} — skipping")
          :skipped
        else
          {:error, "create failed: #{inspect(cs.errors)}"}
        end
    end
  end

  # Resolves the most recent open CRM deal for the given client.
  # Called only when CREATING a new visit — not on re-syncs of existing visits —
  # to avoid hammering Pipedrive on every calendar sync cycle.
  # Returns a deal ID string, or nil if none found / any error occurs.
  defp resolve_crm_deal(client) do
    if is_nil(client.crm_id) or client.crm_id == "" do
      nil
    else
      pd = Application.get_env(:florina, :pipedrive_client, Florina.Integrations.Pipedrive)

      case pd.do_get_organization_deals(client.crm_id) do
        {:ok, deals} when is_list(deals) ->
          # Prefer an open deal; fall back to the most-recent deal of any status.
          # The Pipedrive impl already sorts open/won first, then by update_time desc.
          open_deal = Enum.find(deals, fn d -> d["status"] == "open" end)
          best = open_deal || List.first(deals)

          case best do
            %{"id" => deal_id} -> to_string(deal_id)
            _ -> nil
          end

        {:error, reason} ->
          Logger.warning(
            "[CalendarSync] resolve_crm_deal failed for client=#{client.name}: #{inspect(reason)}"
          )

          nil

        _ ->
          nil
      end
    end
  rescue
    e ->
      Logger.warning("[CalendarSync] resolve_crm_deal error: #{Exception.message(e)}")
      nil
  end

  defp maybe_change(map, old, new, key) when old != new, do: Map.put(map, key, new)
  defp maybe_change(map, _old, _new, _key), do: map
end
