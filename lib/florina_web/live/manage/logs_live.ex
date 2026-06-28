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
      <h1 class="text-2xl font-semibold mb-1 text-gray-900 dark:text-white">Logs</h1>
      <p class="text-sm text-gray-500 dark:text-gray-400 mb-6">
        Immutable record of system and user actions.
      </p>

      <.form for={%{}} as={:filters} phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4">
        <label class="text-sm">
          <span class="block text-xs text-gray-500 dark:text-gray-400 mb-1">Level</span>
          <select name="filters[level]" class={sel()}>
            <option value="" selected={@filters["level"] == ""}>All</option>
            <option :for={l <- level_options()} value={l} selected={@filters["level"] == l}>
              {l}
            </option>
          </select>
        </label>
        <label class="text-sm">
          <span class="block text-xs text-gray-500 dark:text-gray-400 mb-1">User</span>
          <select name="filters[user_id]" class={sel()}>
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
        <button
          type="button"
          phx-click="clear"
          class="rounded-md px-3 py-1.5 text-sm font-semibold text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-white/10"
        >
          Clear
        </button>
      </.form>

      <div class="overflow-x-auto rounded-lg border border-gray-200 dark:border-white/10">
        <table class="w-full text-left text-sm">
          <thead class="bg-gray-50 dark:bg-white/5">
            <tr>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">Time</th>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">Level</th>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">Action</th>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">User</th>
              <th class="px-3 py-2 font-semibold text-gray-900 dark:text-white">Details</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@logs == []}>
              <td colspan="5" class="px-3 py-8 text-center text-gray-400">
                No log entries match these filters.
              </td>
            </tr>
            <tr :for={log <- @logs} class="border-t border-gray-200 align-top dark:border-white/10">
              <td class="px-3 py-2 whitespace-nowrap text-gray-600 dark:text-gray-300">
                {time_label(log.timestamp)}
              </td>
              <td class="px-3 py-2">
                <span class={["rounded-full px-2 py-0.5 text-xs font-medium", level_tone(log.level)]}>
                  {log.level}
                </span>
              </td>
              <td class="px-3 py-2 font-medium text-gray-900 dark:text-white">{log.action}</td>
              <td class="px-3 py-2 whitespace-nowrap text-gray-700 dark:text-gray-300">
                {user_label(log.user)}
              </td>
              <td class="px-3 py-2 max-w-md">
                <details :if={is_map(log.details) and map_size(log.details) > 0}>
                  <summary class="cursor-pointer text-gray-500 dark:text-gray-400 text-xs">
                    details
                  </summary>
                  <pre class="mt-1 whitespace-pre-wrap text-xs text-gray-600 dark:text-gray-300">{pretty(log.details)}</pre>
                </details>
                <span
                  :if={!(is_map(log.details) and map_size(log.details) > 0)}
                  class="text-gray-400"
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

  # Shared TW Plus styling for the filter selects.
  defp sel,
    do:
      "rounded-md bg-white py-1.5 pl-3 pr-8 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500"

  defp level_tone(:ERROR), do: "bg-red-100 text-red-700 dark:bg-red-500/10 dark:text-red-400"
  defp level_tone(:CRITICAL), do: "bg-red-200 text-red-800 dark:bg-red-500/20 dark:text-red-300"

  defp level_tone(:WARNING),
    do: "bg-yellow-100 text-yellow-700 dark:bg-yellow-500/10 dark:text-yellow-400"

  defp level_tone(:INFO), do: "bg-blue-100 text-blue-700 dark:bg-blue-500/10 dark:text-blue-400"
  defp level_tone(_), do: "bg-gray-100 text-gray-700 dark:bg-white/10 dark:text-gray-200"

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
