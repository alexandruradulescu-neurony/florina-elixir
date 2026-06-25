defmodule Florina.Calendar do
  @moduledoc """
  Context for Google Calendar push-notification watch channels
  (`voice_googlecalendarwatch`). Per-tenant.
  """
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.Calendar.GoogleCalendarWatch

  # --- Watch channels -----------------------------------------------------

  @doc "Create a calendar watch channel (sets created_at if absent)."
  def create_watch(attrs) do
    attrs = Map.put_new(attrs, :created_at, now())
    %GoogleCalendarWatch{} |> GoogleCalendarWatch.changeset(attrs) |> TenantRepo.insert()
  end

  def get_watch_by_channel(channel_id),
    do: TenantRepo.get_by(GoogleCalendarWatch, channel_id: channel_id)

  def list_watches, do: TenantRepo.all(GoogleCalendarWatch)

  @doc "Watches expiring at/before the given datetime (used to renew them)."
  def list_expiring_watches(%DateTime{} = before),
    do: TenantRepo.all(from w in GoogleCalendarWatch, where: w.expiration <= ^before)

  def delete_watch(%GoogleCalendarWatch{} = watch), do: TenantRepo.delete(watch)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
