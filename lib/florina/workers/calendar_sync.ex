defmodule Florina.Workers.CalendarSync do
  @moduledoc """
  Per-tenant calendar sync + visit detection.

  Enqueued by `CalendarSyncScheduler`. For each sales agent with stored
  Google OAuth credentials:

    1. Lists today's calendar events via `Florina.Integrations.GoogleCalendar`.
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
  alias Florina.Calendar
  alias Florina.Clients
  alias Florina.Visits
  alias Florina.Visits.Visit
  alias Florina.Services.VisitPipeline
  alias Florina.Workers.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug}}) do
    Tenant.pin!(slug)

    agents = Accounts.list_agents()
    now = DateTime.utc_now()
    today_start = %{now | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    today_end = %{now | hour: 23, minute: 59, second: 59, microsecond: {0, 0}}

    results =
      Enum.map(agents, fn agent ->
        {agent.username, sync_agent(agent, today_start, today_end)}
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
  end

  # ---------------------------------------------------------------------------
  # Per-agent sync
  # ---------------------------------------------------------------------------

  defp sync_agent(agent, today_start, today_end) do
    acc = %{created: 0, updated: 0, skipped: 0, errors: []}

    case Calendar.get_credential_for_user(agent.id) do
      nil ->
        Logger.debug("[CalendarSync] agent=#{agent.username} has no Google credential — skip")
        acc

      cred ->
        gc =
          Application.get_env(
            :florina,
            :google_calendar_client,
            Florina.Integrations.GoogleCalendar
          )

        case gc.do_list_events(cred, today_start, today_end) do
          {:ok, events} ->
            Enum.reduce(events, acc, fn event, a ->
              case process_event(agent, event) do
                {:created, _} -> %{a | created: a.created + 1}
                {:updated, _} -> %{a | updated: a.updated + 1}
                :skipped -> %{a | skipped: a.skipped + 1}
                {:error, msg} -> %{a | errors: [msg | a.errors]}
              end
            end)

          {:error, reason} ->
            msg = "CalendarSync agent=#{agent.username} fetch error: #{inspect(reason)}"
            Logger.error("[CalendarSync] #{msg}")
            %{acc | errors: [msg]}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Per-event processing
  # ---------------------------------------------------------------------------

  defp process_event(agent, %{id: event_id, attendees: attendees} = event) do
    case match_client_by_attendees(attendees) do
      nil ->
        :skipped

      client ->
        case find_existing_visit(event_id, agent.id) do
          %Visit{} = existing ->
            update_visit_if_changed(existing, event)

          nil ->
            create_visit(agent, client, event)
        end
    end
  rescue
    e ->
      {:error, "event=#{Map.get(event, :id, "?")} error: #{Exception.message(e)}"}
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

  defp find_existing_visit(event_id, agent_id) do
    from(v in Visit,
      where: v.calendar_event_id == ^event_id and v.agent_id == ^agent_id
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

  defp create_visit(agent, client, event) do
    crm_deal_id = resolve_crm_deal(client)

    attrs = %{
      agent_id: agent.id,
      client_id: client.id,
      calendar_event_id: event.id,
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

      {:error, cs} ->
        {:error, "create failed: #{inspect(cs.errors)}"}
    end
  end

  defp resolve_crm_deal(client) do
    if is_nil(client.crm_id) or client.crm_id == "" do
      nil
    else
      pd = Application.get_env(:florina, :pipedrive_client, Florina.Integrations.Pipedrive)

      case pd.do_get_organization_deals(client.crm_id) do
        {:ok, [%{"id" => deal_id} | _]} -> to_string(deal_id)
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp maybe_change(map, old, new, key) when old != new, do: Map.put(map, key, new)
  defp maybe_change(map, _old, _new, _key), do: map
end
