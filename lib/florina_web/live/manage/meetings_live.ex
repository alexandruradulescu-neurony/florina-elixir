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
        <h1 class="text-2xl font-semibold">Meetings</h1>
        <.link
          navigate={"/t/#{@tenant.slug}/manage/meetings/new"}
          class="inline-flex items-center gap-1 rounded-md bg-primary px-3 py-2 text-sm font-semibold text-primary-content hover:opacity-90"
        >
          <.icon name="hero-plus" class="size-4" /> New meeting
        </.link>
      </div>
      <div class="overflow-hidden border border-base-300 rounded-lg">
        <table class="w-full text-sm text-left">
          <thead class="bg-base-200 text-xs uppercase tracking-wider text-base-content/60">
            <tr>
              <th class="px-4 py-3">When</th>
              <th class="px-4 py-3">Title</th>
              <th class="px-4 py-3">Agent</th>
              <th class="px-4 py-3">Client</th>
              <th class="px-4 py-3">Status</th>
              <th class="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr :for={v <- @visits} class="hover:bg-base-200/50">
              <td class="px-4 py-3 whitespace-nowrap">{when_label(v.start_time)}</td>
              <td class="px-4 py-3 font-medium">{v.title}</td>
              <td class="px-4 py-3">{agent_label(v.agent)}</td>
              <td class="px-4 py-3">{client_label(v.client)}</td>
              <td class="px-4 py-3">
                <span class="text-xs rounded px-2 py-0.5 bg-base-200">{to_string(v.status)}</span>
              </td>
              <td class="px-4 py-3 text-right">
                <.link
                  navigate={"/t/#{@tenant.slug}/manage/meetings/#{v.id}"}
                  class="text-sm text-primary hover:underline"
                >
                  Edit
                </.link>
              </td>
            </tr>
            <tr :if={@visits == []}>
              <td colspan="6" class="px-4 py-6 text-center text-base-content/40 text-sm">
                No meetings yet.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.agent_app>
    """
  end

  defp when_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %Y · %H:%M")

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
