defmodule Florina.Tz do
  @moduledoc """
  Display-timezone helpers.

  All datetimes are **stored in UTC**; scheduling and storage stay in UTC. These
  helpers convert to the app's local zone (Europe/Bucharest, DST-aware — +2 in
  winter, +3 in summer) for display and for interpreting user-entered times.

  A single app-wide zone for now (the product is Romanian); a per-tenant zone can
  be layered on later by threading the tenant through these calls.
  """

  @zone "Europe/Bucharest"

  @doc "The app's local IANA zone."
  def zone, do: @zone

  @doc "Convert a UTC DateTime to the local zone. Non-datetimes pass through."
  def local(%DateTime{} = dt), do: DateTime.shift_zone!(dt, @zone)
  def local(other), do: other

  @doc """
  Format a UTC `DateTime` in local time using a named style. The single source of
  truth for human-facing time strings — web views AND the voice/prompt paths use
  this so a meeting never reads one time on screen and another on the phone.

  `nil` → `""`. Styles:
  - `:time`             → `14:30`
  - `:short`            → `03 Jul · 14:30`
  - `:datetime`         → `03 Jul 2026 · 14:30` (default)
  - `:datetime_seconds` → `03 Jul 2026 · 14:30:05`
  - `:day_time`         → `Fri 14:30`
  - `:date`             → `03 Jul 2026`
  - `:long`             → `3 July 2026, 14:30`
  - `:iso_date`         → `2026-07-03`
  """
  def format(dt, style \\ :datetime)
  def format(nil, _style), do: ""
  def format(%DateTime{} = dt, style), do: dt |> local() |> Calendar.strftime(pattern(style))

  defp pattern(:time), do: "%H:%M"
  defp pattern(:short), do: "%d %b · %H:%M"
  defp pattern(:datetime), do: "%d %b %Y · %H:%M"
  defp pattern(:datetime_seconds), do: "%d %b %Y · %H:%M:%S"
  defp pattern(:day_time), do: "%a %H:%M"
  defp pattern(:date), do: "%d %b %Y"
  defp pattern(:long), do: "%d %B %Y, %H:%M"
  defp pattern(:iso_date), do: "%Y-%m-%d"

  @doc "Today's date in the local zone."
  def today, do: DateTime.utc_now() |> DateTime.shift_zone!(@zone) |> DateTime.to_date()

  @doc """
  UTC start/end instants for a *local* calendar date, as `{utc_start, utc_end}`.
  Used to query \"meetings on this local day\" against UTC-stored timestamps.
  """
  def day_bounds(%Date{} = date) do
    start_utc = date |> DateTime.new!(~T[00:00:00], @zone) |> DateTime.shift_zone!("Etc/UTC")
    end_utc = date |> DateTime.new!(~T[23:59:59], @zone) |> DateTime.shift_zone!("Etc/UTC")
    {start_utc, end_utc}
  end

  @doc """
  Interpret a local `Date` + `Time` as a UTC `DateTime` (for storing user input).
  Returns `{:ok, utc_dt}` or a non-ok tuple on a DST gap/ambiguity.
  """
  def to_utc(%Date{} = date, %Time{} = time) do
    case DateTime.new(date, time, @zone) do
      {:ok, dt} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      other -> other
    end
  end
end
