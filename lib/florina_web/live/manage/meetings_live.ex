defmodule FlorinaWeb.Manage.MeetingsLive do
  @moduledoc "Manager view of every meeting (visit) in the tenant, newest first. Managers only."
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.Visits

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :visits, Visits.list_all())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:meetings}
    >
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-semibold text-gray-900 dark:text-white">Meetings</h1>
        <.button navigate={"/t/#{@tenant.slug}/manage/meetings/new"} variant="primary">
          <.icon name="hero-plus" class="size-4" /> New meeting
        </.button>
      </div>
      <div class="overflow-hidden border border-gray-200 rounded-lg dark:border-white/10">
        <table class="w-full text-sm text-left">
          <thead class="bg-gray-50 text-xs uppercase tracking-wider text-gray-500 dark:bg-white/5 dark:text-gray-400">
            <tr>
              <th class="px-4 py-3 font-semibold">When</th>
              <th class="px-4 py-3 font-semibold">Title</th>
              <th class="px-4 py-3 font-semibold">Agent</th>
              <th class="px-4 py-3 font-semibold">Client</th>
              <th class="px-4 py-3 font-semibold">Status</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200 dark:divide-white/10">
            <tr :for={v <- @visits} class="hover:bg-gray-50 dark:hover:bg-white/5">
              <td class="px-4 py-3 whitespace-nowrap text-gray-700 dark:text-gray-300">
                {when_label(v.start_time)}
              </td>
              <td class="px-4 py-3 font-medium text-gray-900 dark:text-white">{v.title}</td>
              <td class="px-4 py-3 text-gray-700 dark:text-gray-300">{agent_label(v.agent)}</td>
              <td class="px-4 py-3 text-gray-700 dark:text-gray-300">{client_label(v.client)}</td>
              <td class="px-4 py-3">
                <span class="text-xs rounded px-2 py-0.5 bg-gray-100 text-gray-600 dark:bg-white/10 dark:text-gray-300">
                  {to_string(v.status)}
                </span>
              </td>
              <td class="px-4 py-3 text-right">
                <.link
                  navigate={"/t/#{@tenant.slug}/manage/meetings/#{v.id}"}
                  class="text-sm font-medium text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
                >
                  Edit
                </.link>
              </td>
            </tr>
            <tr :if={@visits == []}>
              <td colspan="6" class="px-4 py-6 text-center text-gray-400 text-sm">
                No meetings yet.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.agent_app>
    """
  end

  defp when_label(%DateTime{} = dt),
    do: Calendar.strftime(Florina.Tz.local(dt), "%d %b %Y · %H:%M")

  defp agent_label(%{first_name: f, last_name: l, email: e}), do: name_of(f, l, e)
  defp agent_label(_), do: "—"
  defp client_label(%{name: n}) when is_binary(n), do: n
  defp client_label(_), do: "—"

  defp name_of(f, l, e) do
    case [f, l] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> e || "—"
      n -> n
    end
  end
end
