defmodule Florina.Calls do
  @moduledoc "Context for the call real-time edge."
  import Ecto.Query, only: [from: 2, order_by: 2, limit: 2]
  alias Florina.TenantRepo
  alias Florina.Calls.CallAttempt
  alias Florina.Strings
  alias Florina.Visits.Visit

  @doc "PubSub topic scoped to a single tenant."
  def topic(tenant_slug), do: "calls:" <> tenant_slug

  @doc """
  Recent calls, most-recently-updated first.

  `scope` is `Florina.Authz.scope/1`: `:all` (managers see every call) or
  `{:own, agent_id}` (agents see only calls whose visit they own). The owner
  filter is applied in SQL via a join on the visit, so it can't be bypassed.
  """
  def list_recent(scope \\ :all, max \\ 50) do
    CallAttempt
    |> scope_calls(scope)
    |> order_by(desc: :updated_at)
    |> limit(^max)
    |> TenantRepo.all()
  end

  defp scope_calls(query, :all), do: query

  defp scope_calls(query, {:own, agent_id}) do
    from c in query,
      join: v in Visit,
      on: c.visit_id == v.id,
      where: v.agent_id == ^agent_id
  end

  @doc """
  Manager view of every call attempt, newest-updated first, with the call's visit
  (and that visit's agent + client) preloaded for display.

  `filters` is a plain map (string keys, as they arrive from a form). Blank values
  are ignored:

    * `"status"`   — one of the `Enums.call_status_values/0` strings
    * `"phase"`    — `"PRE"` | `"POST"`
    * `"agent_id"` — restrict to calls whose visit belongs to this agent

  Manager-only: no owner scoping. Mirrors Django's `programmed_calls` view.
  """
  def list_for_manager(filters \\ %{}, max \\ 200) do
    from(c in CallAttempt,
      join: v in Visit,
      on: c.visit_id == v.id,
      preload: [visit: [:agent, :client]],
      order_by: [desc: c.updated_at]
    )
    |> filter_status(Strings.blank_to_nil(filters["status"]))
    |> filter_phase(Strings.blank_to_nil(filters["phase"]))
    |> filter_agent(Strings.to_int(filters["agent_id"]))
    |> limit(^max)
    |> TenantRepo.all()
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: from(c in query, where: c.status == ^status)

  defp filter_phase(query, nil), do: query
  defp filter_phase(query, phase), do: from(c in query, where: c.phase == ^phase)

  defp filter_agent(query, nil), do: query

  defp filter_agent(query, agent_id),
    do: from([c, v] in query, where: v.agent_id == ^agent_id)

  @doc """
  Counts for the Programmed Calls stats strip, across all calls (unfiltered):
  `%{total:, scheduled:, active:, completed:, failed:}` where `active` groups
  INITIATED + IN_PROGRESS and `failed` groups FAILED + NO_ANSWER.
  """
  def status_counts do
    rows =
      from(c in CallAttempt, group_by: c.status, select: {c.status, count(c.id)})
      |> TenantRepo.all()
      |> Map.new()

    n = fn keys -> keys |> Enum.map(&Map.get(rows, &1, 0)) |> Enum.sum() end

    %{
      total: rows |> Map.values() |> Enum.sum(),
      scheduled: n.(["SCHEDULED"]),
      active: n.(["INITIATED", "IN_PROGRESS"]),
      completed: n.(["COMPLETED"]),
      failed: n.(["FAILED", "NO_ANSWER"])
    }
  end

  @doc """
  True if `call`'s visit is owned by `agent_id`. Used to decide whether a
  realtime `:call_updated` broadcast should reach a given agent's live view.
  """
  def owned_by_agent?(%CallAttempt{visit_id: nil}, _agent_id), do: false

  def owned_by_agent?(%CallAttempt{visit_id: visit_id}, agent_id) do
    case TenantRepo.get(Visit, visit_id) do
      %Visit{agent_id: ^agent_id} -> true
      _ -> false
    end
  end

  def get_by_external_id(nil), do: nil

  def get_by_external_id(external_id),
    do: TenantRepo.get_by(CallAttempt, external_call_id: external_id)

  def get(id), do: TenantRepo.get(CallAttempt, id)

  @doc """
  Apply an ElevenLabs post-call webhook payload to the matching call row. Only the
  transcription event carries call status/transcript; other event types (e.g.
  `post_call_audio`) share the conversation_id but no status, so running them
  through the interpreter would wrongly mark a live call FAILED — those are ignored.
  """
  def apply_elevenlabs_webhook(%{"type" => type}, _tenant_slug)
      when is_binary(type) and type != "post_call_transcription" do
    {:ok, :ignored}
  end

  def apply_elevenlabs_webhook(%{} = payload, tenant_slug) do
    data = Map.get(payload, "data", payload)
    conversation_id = data["conversation_id"]
    call_attempt_id = get_in(data, ["metadata", "call_attempt_id"])

    case find_call(conversation_id, call_attempt_id) do
      nil ->
        {:error, :not_found}

      %CallAttempt{} = ca ->
        attrs =
          data
          |> interpret_conversation(ca.status)
          |> maybe_bind_external_id(ca, conversation_id)

        with {:ok, updated} <- ca |> CallAttempt.webhook_changeset(attrs) |> TenantRepo.update() do
          Phoenix.PubSub.broadcast(Florina.PubSub, topic(tenant_slug), {:call_updated, updated})
          maybe_enqueue_post_completion(updated, tenant_slug)
          {:ok, updated}
        end
    end
  end

  @doc """
  Enqueue the post-call pipeline (lessons distillation + visit → COMPLETE) when a
  POST-phase call has completed. Oban-unique per (call_attempt_id, tenant_slug),
  so the webhook and the polling fallback (`SyncPendingCalls`) can't double-run
  it. No-op for any other phase/status.
  """
  def maybe_enqueue_post_completion(
        %CallAttempt{phase: "POST", status: "COMPLETED", id: id},
        tenant_slug
      )
      when is_binary(tenant_slug) do
    %{"call_attempt_id" => id, "tenant_slug" => tenant_slug}
    |> Florina.Workers.PostCallCompletion.new()
    |> Oban.insert()

    :ok
  end

  def maybe_enqueue_post_completion(_call_attempt, _tenant_slug), do: :ok

  defp find_call(conversation_id, nil), do: get_by_external_id(conversation_id)

  defp find_call(conversation_id, call_attempt_id) do
    get_by_external_id(conversation_id) || match_by_attempt_id(conversation_id, call_attempt_id)
  end

  # Fallback for the first webhook of a call, before its ElevenLabs
  # conversation_id has been stored as `external_call_id`. Only trust the
  # echoed-back `call_attempt_id` when the attempt isn't already bound to a
  # *different* conversation — otherwise a mismatched conversation_id could bind
  # the webhook payload to the wrong call.
  defp match_by_attempt_id(conversation_id, call_attempt_id) do
    case get(call_attempt_id) do
      %CallAttempt{external_call_id: nil} = ca -> ca
      %CallAttempt{external_call_id: ^conversation_id} = ca -> ca
      _ -> nil
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # On the first webhook matched via call_attempt_id (external_call_id not yet
  # stored), bind the ElevenLabs conversation_id so later metadata-less webhooks
  # for the same conversation resolve by external id.
  defp maybe_bind_external_id(attrs, %CallAttempt{external_call_id: x}, conv_id)
       when x in [nil, ""] and is_binary(conv_id) and conv_id != "",
       do: Map.put(attrs, :external_call_id, conv_id)

  defp maybe_bind_external_id(attrs, _ca, _conv_id), do: attrs

  # Only a COMPLETED call is FROZEN: a late or duplicate payload (often statusless
  # and transcriptless) must never regress a success to FAILED — that would corrupt
  # stats and re-open the visit to dialing past the cap. A call that first looked
  # FAILED/NO_ANSWER is NOT frozen, so a later transcript/DONE webhook can still
  # upgrade it to COMPLETED (and trigger the post-call pipeline).
  @frozen_statuses ~w(COMPLETED)

  @doc """
  Interpret a raw ElevenLabs conversation payload into the `CallAttempt` fields to
  apply — `%{status: ...}` plus `:transcript`/`:summary` when present. Shared by
  BOTH the webhook path (`apply_elevenlabs_webhook/2`) and the polling fallback
  (`Florina.Workers.SyncPendingCalls`) so the two interpretations can't drift.

  `existing_status` freezes a COMPLETED call so a late/duplicate payload can't
  un-complete it; transcript/summary may still be backfilled.
  """
  def interpret_conversation(data, existing_status \\ nil) when is_map(data) do
    transcript = extract_transcript(data["transcript"] || data["conversation_transcript"])

    summary =
      get_in(data, ["analysis", "transcript_summary"]) || get_in(data, ["analysis", "summary"])

    status =
      if frozen_status?(existing_status),
        do: existing_status,
        else: map_status(data["status"] || data["call_status"], transcript)

    %{status: status}
    |> maybe_put(:transcript, transcript)
    |> maybe_put(:summary, summary)
  end

  defp frozen_status?(status), do: status in @frozen_statuses

  # ElevenLabs status -> our CallStatus. "DONE" or a present transcript => COMPLETED.
  defp map_status(status, transcript) do
    case status |> to_string() |> String.upcase() do
      "IN_PROGRESS" -> "IN_PROGRESS"
      "RINGING" -> "IN_PROGRESS"
      "FAILED" -> "FAILED"
      "NO_ANSWER" -> "NO_ANSWER"
      "DONE" -> "COMPLETED"
      _ -> if transcript not in [nil, ""], do: "COMPLETED", else: "FAILED"
    end
  end

  # Normalize a transcript payload (a list of turns, or a raw string) to text with
  # "Role: message" lines, or nil when empty.
  defp extract_transcript(list) when is_list(list) do
    case Enum.flat_map(list, &transcript_line/1) do
      [] -> nil
      lines -> Enum.join(lines, "\n\n")
    end
  end

  defp extract_transcript(%{"text" => text}) when is_binary(text), do: nil_if_blank(text)
  defp extract_transcript(text) when is_binary(text), do: nil_if_blank(text)
  defp extract_transcript(_), do: nil

  defp transcript_line(turn) when is_map(turn) do
    case turn["message"] || turn["content"] || turn["text"] do
      msg when is_binary(msg) and msg != "" ->
        role = (turn["role"] || "unknown") |> to_string() |> String.capitalize()
        ["#{role}: #{msg}"]

      _ ->
        []
    end
  end

  defp transcript_line(_), do: []

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s
end
