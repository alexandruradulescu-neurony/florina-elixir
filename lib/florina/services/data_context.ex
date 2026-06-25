defmodule Florina.Services.DataContext do
  @moduledoc """
  Assembles the context bundle (placeholder → value map) for the Auto Prompt
  Assembler, for each of its three domains:

  - `build_pre_call/1`   — for a `%Visit{}` before the client meeting
  - `build_post_call/2`  — for a `%Visit{}` + optional transcript after the meeting
  - `build_lessons/3`    — for a `%Client{}` after a post-call (lessons distillation)

  All fencing of untrusted fields is delegated to `Florina.Services.Placeholders`.
  Mirrors `voice/services/prompt_context.py`.
  """

  import Ecto.Query, only: [from: 2]

  alias Florina.TenantRepo
  alias Florina.Visits.Visit
  alias Florina.Clients.Client
  alias Florina.Visits
  alias Florina.Services.Placeholders

  # ---------------------------------------------------------------------------
  # Formatting helpers
  # ---------------------------------------------------------------------------

  defp fmt_local_date(nil), do: "?"

  defp fmt_local_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d")
  end

  defp fmt_local_datetime(nil), do: ""

  defp fmt_local_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%d %B %Y, %H:%M")
  end

  defp format_interaction_history(nil), do: ""
  defp format_interaction_history([]), do: ""

  defp format_interaction_history(interactions) when is_list(interactions) do
    interactions
    |> Enum.take(5)
    |> Enum.map(fn it ->
      kind = Map.get(it, "type", "note")
      date = Map.get(it, "date", "")
      content = (Map.get(it, "content") || "") |> String.slice(0, 200)
      "- [#{kind}] #{date}: #{content}"
    end)
    |> Enum.join("\n")
  end

  defp format_deal_history(nil), do: ""
  defp format_deal_history([]), do: ""

  defp format_deal_history(deals) when is_list(deals) do
    deals
    |> Enum.take(3)
    |> Enum.map(fn d ->
      title = Map.get(d, "title", "Untitled")
      status = Map.get(d, "status", "unknown")
      "- #{title} (status: #{status})"
    end)
    |> Enum.join("\n")
  end

  defp format_past_visits([]), do: ""
  defp format_past_visits(nil), do: ""

  defp format_past_visits(visits) when is_list(visits) do
    visits
    |> Enum.map(fn v ->
      date = fmt_local_date(v.start_time)
      summary = (v.post_call_summary || "") |> String.trim()

      if summary != "" do
        preview = String.slice(summary, 0, 400)
        "- #{date} · #{v.title}\n  #{preview}"
      else
        "- #{date} · #{v.title} (no debrief)"
      end
    end)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # Past-visit queries
  # ---------------------------------------------------------------------------

  defp past_client_visits(client_id, exclude_id) do
    from(v in Visit,
      where: v.client_id == ^client_id and v.id != ^exclude_id,
      order_by: [desc: v.start_time],
      limit: 3
    )
    |> TenantRepo.all()
  end

  defp past_agent_visits(agent_id, exclude_id) do
    from(v in Visit,
      where: v.agent_id == ^agent_id and v.id != ^exclude_id,
      order_by: [desc: v.start_time],
      limit: 5
    )
    |> TenantRepo.all()
  end

  # ---------------------------------------------------------------------------
  # Public builders
  # ---------------------------------------------------------------------------

  @doc """
  Build the placeholder context map for a PRE_CALL assembly.

  Expects `visit` to have `:agent`, `:client`, `:scenario` preloaded
  (or they will be loaded lazily via TenantRepo).
  """
  def build_pre_call(%Visit{} = visit) do
    client = ensure_client(visit)
    agent = ensure_agent(visit)
    methodology = Visits.effective_methodology(visit)

    past_client = past_client_visits(client.id, visit.id)
    past_agent = past_agent_visits(agent.id, visit.id)

    scenario_name =
      case visit do
        %{scenario: %{name: n}} ->
          n

        %{scenario_id: id} when not is_nil(id) ->
          case TenantRepo.get(Florina.Scenarios.Scenario, id) do
            nil -> ""
            s -> s.name
          end

        _ ->
          ""
      end

    raw = %{
      agent_first_name: agent.first_name || agent.username,
      client_name: client.name,
      client_industry: client.industry || "",
      client_summary: client.ai_summary || "",
      client_lessons_learned: client.lessons_learned || "",
      visit_time: fmt_local_datetime(visit.start_time),
      scenario: scenario_name,
      manager_notes: visit.manager_notes || "",
      methodology_summary: (methodology && methodology.ai_summary) || "",
      interaction_history: format_interaction_history(client.interaction_history),
      deal_history: format_deal_history(client.deal_history),
      client_past_visits: format_past_visits(past_client),
      agent_recent_visits: format_past_visits(past_agent)
    }

    Placeholders.apply_fences(raw)
  end

  @doc """
  Build the placeholder context map for a POST_CALL assembly.

  Extends the pre-call context with `pre_call_brief` (the previously
  generated pre-call prompt) and `visit_transcript`.
  """
  def build_post_call(%Visit{} = visit, transcript \\ "") do
    pre = build_pre_call(visit)

    post_only = %{
      pre_call_brief: visit.pre_call_prompt || "",
      visit_transcript: transcript || ""
    }

    Map.merge(pre, Placeholders.apply_fences(post_only))
  end

  @doc """
  Build the placeholder context map for a LESSONS_DISTILL run.

  Takes a client and the two signals needed by the distill prompt.
  """
  def build_lessons(%Client{} = client, new_post_call_summary, evaluation_outcome \\ "") do
    raw = %{
      current_lessons_learned: client.lessons_learned || "",
      new_post_call_summary: new_post_call_summary || "",
      evaluation_outcome: evaluation_outcome || ""
    }

    Placeholders.apply_fences(raw)
  end

  # ---------------------------------------------------------------------------
  # Chat grounding context
  # ---------------------------------------------------------------------------

  @doc """
  Assembles a bounded text summary of the current tenant's data suitable for
  use as a system-prompt grounding string.

  Must be called from a process that already has a TenantRepo pinned
  (e.g. a LiveView that mounted via `FlorinaWeb.TenantHook`). Do NOT call this
  from inside a spawned Task — build the context first in the pinned process,
  then hand the resulting string to the Task.

  Caps:
  - clients: up to 20
  - upcoming visits: up to 10
  - recent calls: up to 5
  """
  def build_chat_context do
    clients = list_clients_for_chat()
    upcoming = list_upcoming_for_chat()
    recent_calls = list_recent_calls_for_chat()

    clients_text =
      if clients == [] do
        "No clients on record."
      else
        clients
        |> Enum.map(fn c ->
          status = c.status |> to_string()
          "- #{c.name} (status: #{status})"
        end)
        |> Enum.join("\n")
      end

    visits_text =
      if upcoming == [] do
        "No upcoming visits scheduled."
      else
        upcoming
        |> Enum.map(fn v ->
          client_name = if v.client, do: v.client.name, else: "unknown client"

          agent_name =
            if v.agent, do: v.agent.first_name || v.agent.username, else: "unknown agent"

          dt = fmt_local_datetime(v.start_time)
          "- #{dt}: \"#{v.title}\" with #{client_name} (agent: #{agent_name})"
        end)
        |> Enum.join("\n")
      end

    calls_text =
      if recent_calls == [] do
        "No recent calls on record."
      else
        recent_calls
        |> Enum.map(fn ca ->
          summary = (ca.summary || ca.summary_title || "(no summary)") |> String.slice(0, 200)
          "- [#{ca.status}] #{summary}"
        end)
        |> Enum.join("\n")
      end

    """
    You are an assistant for a sales manager. Use the information below to answer questions
    about their clients, upcoming visits, and recent calls. Be concise and helpful.
    If you don't know something that isn't in this data, say so.

    ## Clients (up to 20)
    #{clients_text}

    ## Upcoming visits (next 10)
    #{visits_text}

    ## Recent calls (last 5)
    #{calls_text}
    """
    |> String.trim()
  end

  defp list_clients_for_chat do
    import Ecto.Query, only: [from: 2]

    from(c in Client, order_by: :name, limit: 20)
    |> TenantRepo.all()
  end

  defp list_upcoming_for_chat do
    now = DateTime.utc_now()

    import Ecto.Query, only: [from: 2]

    from(v in Visit,
      where: v.start_time > ^now,
      preload: [:agent, :client],
      order_by: [asc: :start_time],
      limit: 10
    )
    |> TenantRepo.all()
  end

  defp list_recent_calls_for_chat do
    import Ecto.Query, only: [from: 2]

    from(ca in Florina.Calls.CallAttempt,
      order_by: [desc: :updated_at],
      limit: 5
    )
    |> TenantRepo.all()
  end

  # ---------------------------------------------------------------------------
  # Association helpers
  # ---------------------------------------------------------------------------

  defp ensure_client(%Visit{client: %Client{} = c}), do: c
  defp ensure_client(%Visit{client_id: id}), do: TenantRepo.get!(Client, id)

  defp ensure_agent(%Visit{agent: %Florina.Accounts.User{} = a}), do: a
  defp ensure_agent(%Visit{agent_id: id}), do: TenantRepo.get!(Florina.Accounts.User, id)
end
