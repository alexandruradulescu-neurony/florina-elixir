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
      <.header micro="Manage">
        Programmed Calls
        <:subtitle>Every pre- and post-call Florina has scheduled or placed.</:subtitle>
      </.header>

      <div class="grid grid-cols-2 sm:grid-cols-5 gap-3 mb-6">
        <.stat_card label="Total" tone="neutral">{@stats.total}</.stat_card>
        <.stat_card label="Scheduled" tone="neutral">{@stats.scheduled}</.stat_card>
        <.stat_card label="Active" tone="blue">{@stats.active}</.stat_card>
        <.stat_card label="Completed" tone="green">{@stats.completed}</.stat_card>
        <.stat_card label="Failed" tone="rose">{@stats.failed}</.stat_card>
      </div>

      <.form for={%{}} as={:filters} phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4">
        <label class="text-sm">
          <span class="block text-xs text-gray-500 dark:text-gray-400 mb-1">Status</span>
          <select name="filters[status]" class={filter_select()}>
            <option value="" selected={@filters["status"] == ""}>All</option>
            <option :for={s <- status_options()} value={s} selected={@filters["status"] == s}>
              {s}
            </option>
          </select>
        </label>
        <label class="text-sm">
          <span class="block text-xs text-gray-500 dark:text-gray-400 mb-1">Phase</span>
          <select name="filters[phase]" class={filter_select()}>
            <option value="" selected={@filters["phase"] == ""}>All</option>
            <option value="PRE" selected={@filters["phase"] == "PRE"}>Pre-call</option>
            <option value="POST" selected={@filters["phase"] == "POST"}>Post-call</option>
          </select>
        </label>
        <label class="text-sm">
          <span class="block text-xs text-gray-500 dark:text-gray-400 mb-1">Agent</span>
          <select name="filters[agent_id]" class={filter_select()}>
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
        <button
          type="button"
          phx-click="clear"
          class="rounded-md px-3 py-1.5 text-sm font-semibold text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-white/10"
        >
          Clear
        </button>
      </.form>

      <div class="overflow-x-auto rounded-lg border border-gray-200 bg-white dark:border-white/10 dark:bg-white/5">
        <table class="w-full text-left">
          <thead class="border-b border-gray-200 bg-gray-50 dark:border-white/10 dark:bg-white/5">
            <tr>
              <th class={th_class()}>Time</th>
              <th class={th_class()}>Agent</th>
              <th class={th_class()}>Context</th>
              <th class={th_class()}>Phase</th>
              <th class={th_class()}>Status</th>
              <th class={th_class()}>Details</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-200 dark:divide-white/10">
            <tr :if={@calls == []}>
              <td colspan="6" class="px-4 py-10 text-center text-sm text-gray-400">
                No calls match these filters.
              </td>
            </tr>
            <tr :for={call <- @calls} class="hover:bg-gray-50 dark:hover:bg-white/5">
              <td class={[td_top_class(), "whitespace-nowrap text-gray-600 dark:text-gray-400"]}>
                {time_label(call.updated_at)}
              </td>
              <td class={[td_top_class(), "whitespace-nowrap"]}>
                {agent_name(call.visit && call.visit.agent)}
              </td>
              <td class={td_top_class()}>
                <.link
                  :if={call.visit}
                  navigate={"/t/#{@tenant.slug}/manage/meetings/#{call.visit.id}"}
                  class="font-bold text-indigo-600 hover:text-indigo-500 dark:text-indigo-400"
                >
                  {context_label(call.visit)}
                </.link>
                <span :if={is_nil(call.visit)} class="text-gray-400">—</span>
              </td>
              <td class={td_top_class()}>
                <span class="rounded-full bg-gray-100 px-2 py-0.5 text-xs font-semibold text-gray-600 dark:bg-white/10 dark:text-gray-300">
                  {call.phase}
                </span>
              </td>
              <td class={td_top_class()}>
                <span class={[
                  "rounded-full px-2 py-0.5 text-xs font-semibold",
                  status_tone(call.status)
                ]}>
                  {status_label(call.status)}
                </span>
              </td>
              <td class={[td_top_class(), "max-w-md"]}>
                <div :if={call.summary_title} class="font-bold text-gray-900 dark:text-white">
                  {call.summary_title}
                </div>
                <div :if={call.summary} class="text-gray-600 dark:text-gray-300">{call.summary}</div>
                <div :if={snippet(call.transcript)} class="mt-1 text-xs italic text-gray-400">
                  {snippet(call.transcript)}
                </div>
                <audio :if={call.recording_url} controls src={call.recording_url} class="mt-1 h-8" />
                <span
                  :if={
                    blank?(call.summary_title) and blank?(call.summary) and blank?(call.transcript)
                  }
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

  defp status_options, do: Enum.map(Florina.Enums.call_status_values(), fn {_k, v} -> v end)

  # Shared TW Plus select styling for the filter dropdowns.
  defp filter_select,
    do:
      "rounded-md bg-white py-1.5 pl-3 pr-8 text-sm text-gray-900 outline-1 -outline-offset-1 outline-gray-300 focus:outline-2 focus:-outline-offset-2 focus:outline-indigo-600 dark:bg-white/5 dark:text-white dark:outline-white/10 dark:focus:outline-indigo-500"

  defp status_tone("COMPLETED"),
    do: "bg-green-100 text-green-700 dark:bg-green-500/10 dark:text-green-400"

  defp status_tone(s) when s in ["INITIATED", "IN_PROGRESS"],
    do: "bg-blue-100 text-blue-700 dark:bg-blue-500/10 dark:text-blue-400"

  defp status_tone("SCHEDULED"),
    do: "bg-gray-100 text-gray-700 dark:bg-white/10 dark:text-gray-200"

  defp status_tone(s) when s in ["FAILED", "NO_ANSWER"],
    do: "bg-red-100 text-red-700 dark:bg-red-500/10 dark:text-red-400"

  defp status_tone(_), do: "bg-gray-100 text-gray-700 dark:bg-white/10 dark:text-gray-200"

  defp status_label("IN_PROGRESS"), do: "In progress"
  defp status_label("NO_ANSWER"), do: "No answer"
  defp status_label(s), do: s |> String.downcase() |> String.capitalize()

  defp time_label(%DateTime{} = dt), do: Calendar.strftime(Florina.Tz.local(dt), "%d %b · %H:%M")
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
