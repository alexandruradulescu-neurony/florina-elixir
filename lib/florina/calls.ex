defmodule Florina.Calls do
  @moduledoc "Context for the call real-time edge."
  import Ecto.Query, only: [from: 2, order_by: 2, limit: 2]
  alias Florina.TenantRepo
  alias Florina.Calls.CallAttempt
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

  @doc "Apply an ElevenLabs post-call webhook payload to the matching call row."
  def apply_elevenlabs_webhook(%{} = payload, tenant_slug) do
    data = Map.get(payload, "data", payload)
    conversation_id = data["conversation_id"]
    call_attempt_id = get_in(data, ["metadata", "call_attempt_id"])

    case find_call(conversation_id, call_attempt_id) do
      nil ->
        {:error, :not_found}

      %CallAttempt{} = ca ->
        transcript = extract_transcript(data["transcript"])

        summary =
          get_in(data, ["analysis", "transcript_summary"]) ||
            get_in(data, ["analysis", "summary"])

        attrs =
          %{status: map_status(data["status"], transcript)}
          |> maybe_put(:transcript, transcript)
          |> maybe_put(:summary, summary)
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

  # ElevenLabs status -> our CallStatus. "done"/transcript present => COMPLETED.
  defp map_status(status, transcript) do
    case to_string(status) |> String.upcase() do
      "IN_PROGRESS" ->
        "IN_PROGRESS"

      "RINGING" ->
        "IN_PROGRESS"

      "FAILED" ->
        "FAILED"

      "NO_ANSWER" ->
        "NO_ANSWER"

      _ ->
        if transcript not in [nil, ""] or String.downcase(to_string(status)) == "done",
          do: "COMPLETED",
          else: "FAILED"
    end
  end

  defp extract_transcript(list) when is_list(list) do
    list
    |> Enum.map(fn turn -> turn["message"] || turn["text"] || "" end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> nil_if_blank()
  end

  defp extract_transcript(text) when is_binary(text), do: nil_if_blank(text)
  defp extract_transcript(%{"text" => text}) when is_binary(text), do: nil_if_blank(text)
  defp extract_transcript(_), do: nil

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s
end
