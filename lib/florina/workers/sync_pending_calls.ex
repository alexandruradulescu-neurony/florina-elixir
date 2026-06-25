defmodule Florina.Workers.SyncPendingCalls do
  @moduledoc """
  Per-tenant pending-call sync.

  Finds `CallAttempt` rows in non-terminal states (`INITIATED`, `IN_PROGRESS`,
  `SCHEDULED`) that have an `external_call_id` and were last updated more than
  5 minutes ago, then polls ElevenLabs for each and updates status/transcript.

  Mirrors Django's `sync_pending_calls` in `tasks.py` (runs every 15 min).

  Args required: `tenant_slug`.
  """
  use Oban.Worker, queue: :sync, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Florina.TenantRepo
  alias Florina.Calls.CallAttempt
  alias Florina.Workers.Tenant

  @pending_statuses ["INITIATED", "IN_PROGRESS", "SCHEDULED"]
  # Poll only calls that started more than 5 minutes ago (avoid race with webhooks)
  @cutoff_minutes 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug}}) do
    with :ok <- Tenant.pin_active(slug) do
      cutoff = DateTime.add(DateTime.utc_now(), -@cutoff_minutes * 60, :second)

      pending =
        from(ca in CallAttempt,
          where:
            ca.status in ^@pending_statuses and
              not is_nil(ca.external_call_id) and
              ca.updated_at < ^cutoff
        )
        |> TenantRepo.all()

      synced =
        Enum.reduce(pending, 0, fn ca, acc ->
          case sync_one(ca, slug) do
            :synced -> acc + 1
            _other -> acc
          end
        end)

      Logger.info(
        "[SyncPendingCalls] tenant=#{slug} synced=#{synced} of #{length(pending)} pending"
      )

      :ok
    else
      :skip ->
        Logger.info("[SyncPendingCalls] tenant=#{slug} not active — skipping")
        :ok
    end
  end

  defp sync_one(%CallAttempt{external_call_id: ext_id} = ca, slug) do
    el = Application.get_env(:florina, :elevenlabs_client, Florina.Integrations.ElevenLabs)

    case el.do_get_conversation(ext_id) do
      {:ok, data} ->
        apply_conversation_update(ca, data, slug)
        :synced

      {:error, reason} ->
        Logger.warning(
          "[SyncPendingCalls] failed to fetch conversation #{ext_id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp apply_conversation_update(%CallAttempt{} = ca, data, slug) when is_map(data) do
    el_status = data["status"] || data["call_status"]
    transcript_raw = data["transcript"] || data["conversation_transcript"]
    transcript = format_transcript(transcript_raw)

    summary =
      get_in(data, ["analysis", "transcript_summary"]) || get_in(data, ["analysis", "summary"])

    new_status = map_el_status(el_status, transcript)

    attrs =
      %{status: new_status}
      |> maybe_put(:transcript, transcript)
      |> maybe_put(:summary, summary)

    with {:ok, updated} <- ca |> CallAttempt.webhook_changeset(attrs) |> TenantRepo.update() do
      Florina.Calls.maybe_enqueue_post_completion(updated, slug)
      {:ok, updated}
    end
  end

  defp apply_conversation_update(ca, _data, _slug), do: {:ok, ca}

  # Map ElevenLabs status strings to our CallStatus values
  defp map_el_status(status, transcript) do
    case to_string(status) |> String.upcase() do
      "IN_PROGRESS" ->
        "IN_PROGRESS"

      "RINGING" ->
        "IN_PROGRESS"

      "FAILED" ->
        "FAILED"

      "NO_ANSWER" ->
        "NO_ANSWER"

      "DONE" ->
        "COMPLETED"

      _ ->
        if transcript not in [nil, ""], do: "COMPLETED", else: "FAILED"
    end
  end

  defp format_transcript(list) when is_list(list) do
    lines =
      Enum.flat_map(list, fn turn ->
        if is_map(turn) do
          role = turn["role"] || "unknown"
          msg = turn["message"] || turn["content"] || turn["text"]
          if msg, do: ["#{String.capitalize(to_string(role))}: #{msg}"], else: []
        else
          []
        end
      end)

    if lines == [], do: nil, else: Enum.join(lines, "\n\n")
  end

  defp format_transcript(t) when is_binary(t) and t != "", do: t
  defp format_transcript(_), do: nil

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
