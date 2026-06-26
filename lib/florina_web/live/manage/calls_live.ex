defmodule FlorinaWeb.Manage.CallsLive do
  @moduledoc """
  Programmed Calls — the manager's view of every scheduled/executed call attempt.

  A stats strip (Total / Scheduled / Active / Completed / Failed) plus filters by
  status, phase and agent. Rows show when, who, the client/visit context, phase,
  status and a transcript/summary snippet. Managers only.

  Mirrors Django's `/manager/calls/` (`programmed_calls`).
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Accounts, Calls}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Florina.PubSub, Calls.topic(socket.assigns.tenant.slug))

    {:ok,
     socket
     |> assign(:agents, Accounts.list_agents())
     |> assign(:filters, %{"status" => "", "phase" => "", "agent_id" => ""})
     |> load_calls()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, socket |> assign(:filters, filters) |> load_calls()}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, %{"status" => "", "phase" => "", "agent_id" => ""})
     |> load_calls()}
  end

  # A call changed (webhook/dial). Cheapest correct refresh: re-run the query so
  # the row lands in the right filtered/sorted position and the stats stay exact.
  @impl true
  def handle_info({:call_updated, _call}, socket), do: {:noreply, load_calls(socket)}

  defp load_calls(socket) do
    socket
    |> assign(:calls, Calls.list_for_manager(socket.assigns.filters))
    |> assign(:stats, Calls.status_counts())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:programmed_calls}
    >
      <h1 class="text-2xl font-semibold mb-1">Programmed Calls</h1>
      <p class="text-sm text-base-content/60 mb-6">
        Every pre- and post-call Florina has scheduled or placed.
      </p>

      <div class="grid grid-cols-2 sm:grid-cols-5 gap-3 mb-6">
        <.stat label="Total" value={@stats.total} tone="bg-base-200 text-base-content" />
        <.stat label="Scheduled" value={@stats.scheduled} tone="bg-base-200 text-base-content" />
        <.stat label="Active" value={@stats.active} tone="bg-info/10 text-info" />
        <.stat label="Completed" value={@stats.completed} tone="bg-success/10 text-success" />
        <.stat label="Failed" value={@stats.failed} tone="bg-error/10 text-error" />
      </div>

      <.form for={%{}} as={:filters} phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4">
        <label class="text-sm">
          <span class="block text-xs text-base-content/60 mb-1">Status</span>
          <select name="filters[status]" class="select select-bordered select-sm">
            <option value="" selected={@filters["status"] == ""}>All</option>
            <option :for={s <- status_options()} value={s} selected={@filters["status"] == s}>
              {s}
            </option>
          </select>
        </label>
        <label class="text-sm">
          <span class="block text-xs text-base-content/60 mb-1">Phase</span>
          <select name="filters[phase]" class="select select-bordered select-sm">
            <option value="" selected={@filters["phase"] == ""}>All</option>
            <option value="PRE" selected={@filters["phase"] == "PRE"}>Pre-call</option>
            <option value="POST" selected={@filters["phase"] == "POST"}>Post-call</option>
          </select>
        </label>
        <label class="text-sm">
          <span class="block text-xs text-base-content/60 mb-1">Agent</span>
          <select name="filters[agent_id]" class="select select-bordered select-sm">
            <option value="" selected={@filters["agent_id"] == ""}>All</option>
            <option
              :for={a <- @agents}
              value={a.id}
              selected={@filters["agent_id"] == to_string(a.id)}
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
              <th class="px-3 py-2 font-semibold">Agent</th>
              <th class="px-3 py-2 font-semibold">Context</th>
              <th class="px-3 py-2 font-semibold">Phase</th>
              <th class="px-3 py-2 font-semibold">Status</th>
              <th class="px-3 py-2 font-semibold">Details</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@calls == []}>
              <td colspan="6" class="px-3 py-8 text-center text-base-content/50">
                No calls match these filters.
              </td>
            </tr>
            <tr :for={call <- @calls} class="border-t border-base-300 align-top">
              <td class="px-3 py-2 whitespace-nowrap text-base-content/70">
                {time_label(call.updated_at)}
              </td>
              <td class="px-3 py-2 whitespace-nowrap">
                {agent_name(call.visit && call.visit.agent)}
              </td>
              <td class="px-3 py-2">
                <.link
                  :if={call.visit}
                  navigate={"/t/#{@tenant.slug}/manage/meetings/#{call.visit.id}"}
                  class="text-primary hover:underline"
                >
                  {context_label(call.visit)}
                </.link>
                <span :if={is_nil(call.visit)} class="text-base-content/40">—</span>
              </td>
              <td class="px-3 py-2">
                <span class="rounded bg-base-200 px-2 py-0.5 text-xs font-medium">{call.phase}</span>
              </td>
              <td class="px-3 py-2">
                <span class={[
                  "rounded-full px-2 py-0.5 text-xs font-medium",
                  status_tone(call.status)
                ]}>
                  {status_label(call.status)}
                </span>
              </td>
              <td class="px-3 py-2 max-w-md">
                <div :if={call.summary_title} class="font-medium">{call.summary_title}</div>
                <div :if={call.summary} class="text-base-content/70">{call.summary}</div>
                <div :if={snippet(call.transcript)} class="mt-1 text-xs text-base-content/50 italic">
                  {snippet(call.transcript)}
                </div>
                <audio :if={call.recording_url} controls src={call.recording_url} class="mt-1 h-8" />
                <span
                  :if={
                    blank?(call.summary_title) and blank?(call.summary) and blank?(call.transcript)
                  }
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

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div class={["rounded-lg p-3", @tone]}>
      <div class="text-2xl font-semibold">{@value}</div>
      <div class="text-xs opacity-70">{@label}</div>
    </div>
    """
  end

  defp status_options, do: Enum.map(Florina.Enums.call_status_values(), fn {_k, v} -> v end)

  defp status_tone("COMPLETED"), do: "bg-success/10 text-success"
  defp status_tone(s) when s in ["INITIATED", "IN_PROGRESS"], do: "bg-info/10 text-info"
  defp status_tone("SCHEDULED"), do: "bg-base-200 text-base-content"
  defp status_tone(s) when s in ["FAILED", "NO_ANSWER"], do: "bg-error/10 text-error"
  defp status_tone(_), do: "bg-base-200 text-base-content"

  defp status_label("IN_PROGRESS"), do: "In progress"
  defp status_label("NO_ANSWER"), do: "No answer"
  defp status_label(s), do: s |> String.downcase() |> String.capitalize()

  defp time_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b · %H:%M")
  defp time_label(_), do: "—"

  defp context_label(%{title: t}) when is_binary(t) and t != "", do: t
  defp context_label(%{client: %{name: n}}) when is_binary(n), do: n
  defp context_label(_), do: "Visit"

  defp agent_name(%{first_name: f, last_name: l, email: e}) do
    case [f, l] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> e || "—"
      n -> n
    end
  end

  defp agent_name(_), do: "—"

  defp snippet(text) when is_binary(text) and text != "" do
    if String.length(text) > 140, do: String.slice(text, 0, 140) <> "…", else: text
  end

  defp snippet(_), do: nil

  defp blank?(v), do: v in [nil, ""]
end
