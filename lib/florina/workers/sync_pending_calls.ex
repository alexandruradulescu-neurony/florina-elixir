defmodule Florina.Workers.SyncPendingCalls do
  @moduledoc """
  Per-tenant pending-call sync.

  Finds `CallAttempt` rows in non-terminal states (`INITIATED`, `IN_PROGRESS`,
  `SCHEDULED`) that have an `external_call_id` and were last updated more than
  5 minutes ago, then polls ElevenLabs for each and updates status/transcript.

  Mirrors Django's `sync_pending_calls` in `tasks.py` (runs every 15 min).

  Args required: `tenant_slug`.
  """
  # Unique per tenant within a window shorter than the 15-min cron cadence.
  use Oban.Worker, queue: :sync, max_attempts: 3, unique: [period: 300, keys: [:tenant_slug]]

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

  # Interpret the polled conversation through the SAME shared interpreter the
  # webhook path uses (`Florina.Calls.interpret_conversation/2`), passing the
  # current status so a terminal call can't be regressed by a late poll.
  defp apply_conversation_update(%CallAttempt{} = ca, data, slug) when is_map(data) do
    attrs = Florina.Calls.interpret_conversation(data, ca.status)

    with {:ok, updated} <- ca |> CallAttempt.webhook_changeset(attrs) |> TenantRepo.update() do
      Florina.Calls.maybe_enqueue_post_completion(updated, slug)
      {:ok, updated}
    end
  end

  defp apply_conversation_update(ca, _data, _slug), do: {:ok, ca}
end
