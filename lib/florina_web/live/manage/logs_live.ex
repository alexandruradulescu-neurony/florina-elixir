defmodule FlorinaWeb.Manage.LogsLive do
  @moduledoc """
  Read-only audit-log explorer (`voice_activitylog`). Filter by level and user.
  Immutable — no write actions. Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Accounts, Audit}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:agents, Accounts.list_agents())
     |> assign(:filters, %{"level" => "", "user_id" => ""})
     |> load_logs()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket),
    do: {:noreply, socket |> assign(:filters, filters) |> load_logs()}

  def handle_event("clear", _params, socket),
    do: {:noreply, socket |> assign(:filters, %{"level" => "", "user_id" => ""}) |> load_logs()}

  defp load_logs(socket),
    do: assign(socket, :logs, Audit.list_filtered(socket.assigns.filters))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app flash={@flash} tenant={@tenant} current_agent={@current_agent} active={:logs}>
      <h1 class="text-2xl font-semibold mb-1">Logs</h1>
      <p class="text-sm text-base-content/60 mb-6">Immutable record of system and user actions.</p>

      <.form for={%{}} as={:filters} phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4">
        <label class="text-sm">
          <span class="block text-xs text-base-content/60 mb-1">Level</span>
          <select name="filters[level]" class="select select-bordered select-sm">
            <option value="" selected={@filters["level"] == ""}>All</option>
            <option :for={l <- level_options()} value={l} selected={@filters["level"] == l}>
              {l}
            </option>
          </select>
        </label>
        <label class="text-sm">
          <span class="block text-xs text-base-content/60 mb-1">User</span>
          <select name="filters[user_id]" class="select select-bordered select-sm">
            <option value="" selected={@filters["user_id"] == ""}>All</option>
            <option
              :for={a <- @agents}
              value={a.id}
              selected={@filters["user_id"] == to_string(a.id)}
            >
              {agent_name(a)}
            </option>
          </select>
        </label>
        <button type="button" phx-click="clear" class="btn btn-ghost btn-sm">Clear</button>
      </.form>

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="w-full text-left text-sm">
          <thead class="bg-base-200">
            <tr>
              <th class="px-3 py-2 font-semibold">Time</th>
              <th class="px-3 py-2 font-semibold">Level</th>
              <th class="px-3 py-2 font-semibold">Action</th>
              <th class="px-3 py-2 font-semibold">User</th>
              <th class="px-3 py-2 font-semibold">Details</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@logs == []}>
              <td colspan="5" class="px-3 py-8 text-center text-base-content/50">
                No log entries match these filters.
              </td>
            </tr>
            <tr :for={log <- @logs} class="border-t border-base-300 align-top">
              <td class="px-3 py-2 whitespace-nowrap text-base-content/70">
                {time_label(log.timestamp)}
              </td>
              <td class="px-3 py-2">
                <span class={["rounded-full px-2 py-0.5 text-xs font-medium", level_tone(log.level)]}>
                  {log.level}
                </span>
              </td>
              <td class="px-3 py-2 font-medium">{log.action}</td>
              <td class="px-3 py-2 whitespace-nowrap">{user_label(log.user)}</td>
              <td class="px-3 py-2 max-w-md">
                <details :if={is_map(log.details) and map_size(log.details) > 0}>
                  <summary class="cursor-pointer text-base-content/60 text-xs">details</summary>
                  <pre class="mt-1 whitespace-pre-wrap text-xs text-base-content/70">{pretty(log.details)}</pre>
                </details>
                <span
                  :if={!(is_map(log.details) and map_size(log.details) > 0)}
                  class="text-base-content/40"
                >
                  —
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.agent_app>
    """
  end

  defp level_options, do: Enum.map(Florina.Enums.log_level_values(), fn {_k, v} -> v end)

  defp level_tone(:ERROR), do: "bg-error/10 text-error"
  defp level_tone(:CRITICAL), do: "bg-error/20 text-error"
  defp level_tone(:WARNING), do: "bg-warning/10 text-warning"
  defp level_tone(:INFO), do: "bg-info/10 text-info"
  defp level_tone(_), do: "bg-base-200 text-base-content"

  defp time_label(%DateTime{} = dt),
    do: Calendar.strftime(Florina.Tz.local(dt), "%d %b %Y · %H:%M:%S")

  defp time_label(_), do: "—"

  defp user_label(%{} = u), do: agent_name(u)
  defp user_label(_), do: "System"

  defp agent_name(%{first_name: f, last_name: l, email: e}) do
    case [f, l] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> e || "—"
      n -> n
    end
  end

  defp agent_name(_), do: "—"

  defp pretty(map) do
    case Jason.encode(map, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(map)
    end
  end
end
