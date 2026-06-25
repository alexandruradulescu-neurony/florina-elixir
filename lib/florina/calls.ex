defmodule Florina.Calls do
  @moduledoc "Context for the call real-time edge."
  import Ecto.Query, only: [order_by: 2, limit: 2]
  alias Florina.TenantRepo
  alias Florina.Calls.CallAttempt

  @doc "PubSub topic scoped to a single tenant."
  def topic(tenant_slug), do: "calls:" <> tenant_slug

  @doc "Recent calls, most-recently-updated first."
  def list_recent(max \\ 50) do
    CallAttempt
    |> order_by(desc: :updated_at)
    |> limit(^max)
    |> TenantRepo.all()
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
    get_by_external_id(conversation_id) || get(call_attempt_id)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

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
