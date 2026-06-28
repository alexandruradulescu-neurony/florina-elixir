defmodule Florina.CalendarEvents do
  @moduledoc "Per-tenant synced calendar events — the merged-calendar source of truth."
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.Calendar.Event

  @doc "Insert or update one normalized provider event (idempotent on user+provider+external id)."
  def upsert_event(user_id, provider, event) when is_atom(provider) do
    attrs = %{
      user_id: user_id,
      provider: provider,
      external_event_id: event.id,
      title: event[:title],
      description: event[:description],
      location: event[:location],
      start_time: trunc_dt(event.start_time),
      end_time: trunc_dt(event.end_time),
      attendees: normalize_attendees(event[:attendees]),
      status: event[:status],
      raw: event[:raw],
      synced_at: now()
    }

    case TenantRepo.get_by(Event,
           user_id: user_id,
           provider: provider,
           external_event_id: event.id
         ) do
      nil -> %Event{} |> Event.changeset(attrs) |> TenantRepo.insert()
      existing -> existing |> Event.changeset(attrs) |> TenantRepo.update()
    end
  end

  @doc """
  All events whose start falls within `[from_dt, to_dt]`, ordered, with the
  agent preloaded.

  `scope` is `Florina.Authz.scope/1`: `:all` (managers see every agent's events)
  or `{:own, user_id}` (agents see only their own). The owner filter is applied
  in SQL so it can't be bypassed.
  """
  def list_events_between(%DateTime{} = from_dt, %DateTime{} = to_dt, scope \\ :all) do
    Event
    |> where([e], e.start_time >= ^from_dt and e.start_time <= ^to_dt)
    |> where([e], is_nil(e.status) or e.status != "cancelled")
    |> scope_events(scope)
    |> order_by([e], e.start_time)
    |> TenantRepo.all()
    |> TenantRepo.preload(:user)
  end

  defp scope_events(query, :all), do: query
  defp scope_events(query, {:own, user_id}), do: where(query, [e], e.user_id == ^user_id)

  defp normalize_attendees(nil), do: []

  defp normalize_attendees(list) when is_list(list) do
    Enum.map(list, fn
      email when is_binary(email) -> %{"email" => email}
      %{} = m -> m
      other -> %{"email" => to_string(other)}
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp trunc_dt(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp trunc_dt(other), do: other
end
