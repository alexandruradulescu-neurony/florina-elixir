defmodule Florina.Workers.HelloWorker do
  @moduledoc """
  Example background job — exists only to prove Oban is wired up and actually
  processing jobs. Safe to delete or replace once real workers exist.
  """
  use Oban.Worker, queue: :default

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Logger.info("[HelloWorker] processed a job with args: #{inspect(args)}")
    :ok
  end
end
