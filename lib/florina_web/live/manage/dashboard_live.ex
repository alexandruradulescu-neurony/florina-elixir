defmodule FlorinaWeb.Manage.DashboardLive do
  @moduledoc """
  Manager dashboard — answers one question at a glance: "is today under control?"

  Action items needing attention come first (meetings with no methodology, agents
  with no phone, failed calls), then today's meetings with their lifecycle state,
  then recent call activity. Updates live as calls progress. Managers only.
  """
  use FlorinaWeb, :live_view

  on_mount FlorinaWeb.TenantHook
  on_mount {FlorinaWeb.AgentAuth, :ensure_authenticated}
  on_mount {FlorinaWeb.AgentAuth, :require_manager}

  alias Florina.{Calls, Settings, Visits}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Florina.PubSub, Calls.topic(socket.assigns.tenant.slug))

    {:ok, load(socket)}
  end

  @impl true
  def handle_info({:call_updated, _call}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    today = Florina.Tz.today()
    meetings = Visits.list_for_day(today)
    recent_calls = Calls.list_recent(:all, 15)
    default_methodology_id = Settings.get().default_methodology_id

    socket
    |> assign(:today, today)
    |> assign(:meetings, meetings)
    |> assign(:recent_calls, recent_calls)
    |> assign(:attention, attention_items(meetings, recent_calls, default_methodology_id))
  end

  # Build the "needs attention" list, most severe first.
  defp attention_items(meetings, recent_calls, default_methodology_id) do
    meeting_issues =
      Enum.flat_map(meetings, fn v ->
        []
        |> phone_issue(v)
        |> methodology_issue(v, default_methodology_id)
      end)

    call_issues =
      recent_calls
      |> Enum.filter(&(&1.status in ["FAILED", "NO_ANSWER"]))
      |> Enum.map(fn c ->
        %{severity: :error, message: "#{phase_word(c.phase)} call #{String.downcase(c.status)}"}
      end)

    (meeting_issues ++ call_issues) |> Enum.sort_by(&(&1.severity == :error), :desc)
  end

  defp phone_issue(acc, %{agent: %{phone_number: p} = a, title: t}) when p in [nil, ""],
    do: [
      %{severity: :error, message: "#{agent_label(a)} has no phone — can't be called (“#{t}”)"}
      | acc
    ]

  defp phone_issue(acc, _), do: acc

  defp methodology_issue(
         acc,
         %{methodology_id: nil, agent: %{default_methodology_id: nil}} = v,
         nil
       ),
       do: [%{severity: :warning, message: "“#{v.title}” has no methodology set"} | acc]

  defp methodology_issue(acc, _v, _default), do: acc

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.agent_app
      flash={@flash}
      tenant={@tenant}
      current_agent={@current_agent}
      active={:dashboard}
    >
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-semibold">Today</h1>
          <p class="text-sm text-base-content/60">{Calendar.strftime(@today, "%A, %d %B %Y")}</p>
        </div>
        <.link
          navigate={"/t/#{@tenant.slug}/manage/meetings/new"}
          class="inline-flex items-center gap-1 rounded-md bg-primary px-3 py-2 text-sm font-semibold text-primary-content hover:opacity-90"
        >
          <.icon name="hero-plus" class="size-4" /> New meeting
        </.link>
      </div>

      <section :if={@attention != []} class="mb-8">
        <h2 class="text-sm font-semibold text-base-content/60 mb-2">Needs attention</h2>
        <ul class="space-y-2">
          <li
            :for={item <- @attention}
            class={[
              "flex items-center gap-2 rounded-lg border px-3 py-2 text-sm",
              (item.severity == :error && "border-error/30 bg-error/5") ||
                "border-warning/30 bg-warning/5"
            ]}
          >
            <.icon
              name="hero-exclamation-triangle"
              class={[
                "size-4 shrink-0",
                (item.severity == :error && "text-error") || "text-warning"
              ]}
            />
            <span>{item.message}</span>
          </li>
        </ul>
      </section>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <section class="lg:col-span-2">
          <h2 class="text-lg font-medium mb-3">
            Today's meetings <span class="text-base-content/40 text-sm">({length(@meetings)})</span>
          </h2>
          <div class="space-y-2">
            <.link
              :for={v <- @meetings}
              navigate={"/t/#{@tenant.slug}/manage/meetings/#{v.id}"}
              class="flex items-center justify-between rounded-lg border border-base-300 px-3 py-2 hover:bg-base-200/50"
            >
              <div>
                <div class="text-sm font-medium text-base-content">
                  {time(v.start_time)} · {v.title}
                </div>
                <div class="text-xs text-base-content/60">
                  {agent_label(v.agent)} · {client_label(v.client)}
                </div>
              </div>
              <span class={["text-xs rounded-full px-2 py-0.5 font-medium", status_tone(v.status)]}>
                {status_label(v.status)}
              </span>
            </.link>
            <p
              :if={@meetings == []}
              class="text-sm text-base-content/40 rounded-lg border border-dashed border-base-300 px-3 py-6 text-center"
            >
              No meetings today. Calendar sync brings them in, or add one manually.
            </p>
          </div>
        </section>

        <section>
          <h2 class="text-lg font-medium mb-3">Recent calls</h2>
          <div class="space-y-2">
            <div :for={c <- @recent_calls} class="rounded-lg border border-base-300 px-3 py-2">
              <div class="flex items-center justify-between">
                <span class="text-sm font-medium">{phase_word(c.phase)} call</span>
                <span class={["text-xs rounded-full px-2 py-0.5 font-medium", call_tone(c.status)]}>
                  {String.downcase(c.status)}
                </span>
              </div>
              <div :if={c.summary_title} class="text-xs text-base-content/60 mt-0.5">
                {c.summary_title}
              </div>
            </div>
            <p :if={@recent_calls == []} class="text-sm text-base-content/40">
              No call activity yet.
            </p>
          </div>
        </section>
      </div>
    </Layouts.agent_app>
    """
  end

  defp time(%DateTime{} = dt), do: Calendar.strftime(Florina.Tz.local(dt), "%H:%M")

  defp phase_word("PRE"), do: "Pre"
  defp phase_word("POST"), do: "Post"
  defp phase_word(other), do: to_string(other)

  defp status_label(:PLANNED), do: "Planned"
  defp status_label(:PRE_CALL_DONE), do: "Briefed"
  defp status_label(:IN_PROGRESS), do: "In progress"
  defp status_label(:POST_CALL_DONE), do: "Debriefed"
  defp status_label(:COMPLETE), do: "Complete"
  defp status_label(:CANCELLED), do: "Cancelled"
  defp status_label(:MISSED), do: "Missed"
  defp status_label(other), do: to_string(other)

  defp status_tone(:COMPLETE), do: "bg-success/10 text-success"
  defp status_tone(:IN_PROGRESS), do: "bg-info/10 text-info"

  defp status_tone(s) when s in [:CANCELLED, :MISSED],
    do: "bg-base-200 text-base-content/40 line-through"

  defp status_tone(_), do: "bg-base-200 text-base-content/70"

  defp call_tone("COMPLETED"), do: "bg-success/10 text-success"
  defp call_tone(s) when s in ["FAILED", "NO_ANSWER"], do: "bg-error/10 text-error"
  defp call_tone(s) when s in ["INITIATED", "IN_PROGRESS"], do: "bg-info/10 text-info"
  defp call_tone(_), do: "bg-base-200 text-base-content/70"

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
