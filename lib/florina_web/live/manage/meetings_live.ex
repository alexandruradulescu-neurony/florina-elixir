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
      <.header micro="Manage">
        Meetings
        <:actions>
          <.button navigate={"/t/#{@tenant.slug}/manage/meetings/new"} variant="primary">
            <.icon name="hero-plus" class="size-4" /> New meeting
          </.button>
        </:actions>
      </.header>
      <div class="overflow-hidden rounded-lg border border-gray-200 bg-white dark:border-white/10 dark:bg-white/5">
        <table class="w-full text-left">
          <thead class="border-b border-gray-200 bg-gray-50 dark:border-white/10 dark:bg-white/5">
            <tr>
              <th class={th_class()}>When</th>
              <th class={th_class()}>Title</th>
              <th class={th_class()}>Agent</th>
              <th class={th_class()}>Client</th>
              <th class={th_class()}>Status</th>
              <th class={th_class()}></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200 dark:divide-white/10">
            <tr :for={v <- @visits} class="hover:bg-gray-50 dark:hover:bg-white/5">
              <td class={[td_class(), "whitespace-nowrap text-gray-600 dark:text-gray-400"]}>
                {when_label(v.start_time)}
              </td>
              <td class={[td_class(), "font-bold text-gray-900 dark:text-white"]}>{v.title}</td>
              <td class={td_class()}>{agent_label(v.agent)}</td>
              <td class={td_class()}>{client_label(v.client)}</td>
              <td class={td_class()}>
                <span class={["rounded-full px-2 py-0.5 text-xs font-semibold", status_tone(v.status)]}>
                  {status_label(v.status)}
                </span>
              </td>
              <td class={[td_class(), "text-right"]}>
                <.link
                  navigate={"/t/#{@tenant.slug}/manage/meetings/#{v.id}"}
                  class="text-sm font-bold text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
                >
                  Edit
                </.link>
              </td>
            </tr>
            <tr :if={@visits == []}>
              <td colspan="6" class="px-4 py-10 text-center text-sm text-gray-400">
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

  defp status_label(:PLANNED), do: "Planned"
  defp status_label(:PRE_CALL_DONE), do: "Briefed"
  defp status_label(:IN_PROGRESS), do: "In progress"
  defp status_label(:POST_CALL_DONE), do: "Debriefed"
  defp status_label(:COMPLETE), do: "Complete"
  defp status_label(:CANCELLED), do: "Cancelled"
  defp status_label(:MISSED), do: "Missed"
  defp status_label(:ARCHIVED), do: "Archived"
  defp status_label(other), do: to_string(other)

  defp status_tone(:COMPLETE),
    do: "bg-green-100 text-green-700 dark:bg-green-500/10 dark:text-green-400"

  defp status_tone(:IN_PROGRESS),
    do: "bg-blue-100 text-blue-700 dark:bg-blue-500/10 dark:text-blue-400"

  defp status_tone(s) when s in [:CANCELLED, :MISSED, :ARCHIVED],
    do: "bg-gray-100 text-gray-400 line-through dark:bg-white/5 dark:text-gray-500"

  defp status_tone(_), do: "bg-gray-100 text-gray-600 dark:bg-white/10 dark:text-gray-300"

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
