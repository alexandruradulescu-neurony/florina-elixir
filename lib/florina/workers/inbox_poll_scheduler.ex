defmodule Florina.Workers.InboxPollScheduler do
  @moduledoc """
  Periodic cron worker — fans out `InboxPoll` to every active tenant, so each
  tenant's Florina mailbox is checked for new client mail on a fixed cadence.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 3

  alias Florina.Workers.{InboxPoll, TenantFanOut}

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: TenantFanOut.fan_out(InboxPoll, "InboxPollScheduler")
end
