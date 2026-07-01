defmodule Florina.Workers.InboxPollScheduler do
  @moduledoc """
  Periodic cron worker — fans out `InboxPoll` to every active tenant, so each
  tenant's Florina mailbox is checked for new client mail on a fixed cadence.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 3

  require Logger

  alias Florina.Tenants
  alias Florina.Workers.InboxPoll

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tenants = Tenants.list_active()
    Logger.info("[InboxPollScheduler] fanning out to #{length(tenants)} active tenant(s)")

    for tenant <- tenants do
      %{tenant_slug: tenant.slug}
      |> InboxPoll.new()
      |> Oban.insert()
    end

    :ok
  end
end
