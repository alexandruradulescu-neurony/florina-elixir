defmodule Florina.Visits.Attention do
  @moduledoc """
  The single "needs attention" rule shared by the manager dashboard and the
  meetings board, so both flag the same visits the same way.

  A visit is considered only when it is actionable: calls are enabled for it AND
  it is not in a terminal state (cancelled/missed/archived) — the same gate the
  board applies. For each actionable visit it emits any of: agent has no phone
  (error), no methodology set (warning), a call on THAT visit failed (error).

  Failed-call flags are scoped to the visit's own `call_attempts`, so they only
  surface for the visits in the caller's set (e.g. today's, on the dashboard).
  Each item is `%{severity: :error | :warning, message: String.t(), visit_id: id}`,
  sorted errors-first. Callers must preload `:agent` and `:call_attempts`.
  """
  alias Florina.Accounts.User

  @terminal [:CANCELLED, :MISSED, :ARCHIVED]

  @doc """
  Build the attention list for `visits`. `sys_default` is the tenant's default
  methodology id (nil when unset), used to decide whether a visit lacks a
  methodology entirely.
  """
  def items(visits, sys_default) do
    visits
    |> Enum.filter(&actionable?/1)
    |> Enum.flat_map(&issues_for(&1, sys_default))
    |> Enum.sort_by(&(&1.severity == :error), :desc)
  end

  defp actionable?(v), do: v.calls_enabled and v.status not in @terminal

  defp issues_for(v, sys_default) do
    []
    |> add(no_phone?(v), :error, "#{agent_label(v.agent)} has no phone — can't be called")
    |> add(no_methodology?(v, sys_default), :warning, "No methodology set")
    |> add(failed_call?(v), :error, "A call failed — needs a retry")
    |> Enum.map(fn {severity, msg} ->
      %{severity: severity, message: "#{v.title} — #{msg}", visit_id: v.id}
    end)
  end

  defp add(acc, true, severity, msg), do: [{severity, msg} | acc]
  defp add(acc, false, _severity, _msg), do: acc

  defp no_phone?(%{agent: %{phone_number: p}}), do: p in [nil, ""]
  defp no_phone?(_), do: false

  defp no_methodology?(%{methodology_id: nil, agent: %{default_methodology_id: nil}}, nil),
    do: true

  defp no_methodology?(_, _), do: false

  defp failed_call?(%{call_attempts: attempts}) when is_list(attempts),
    do: Enum.any?(attempts, &(&1.status in ["FAILED", "NO_ANSWER"]))

  defp failed_call?(_), do: false

  defp agent_label(agent), do: User.display_name(agent) || "—"
end
