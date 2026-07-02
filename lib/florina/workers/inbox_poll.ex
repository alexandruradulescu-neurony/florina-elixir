defmodule Florina.Workers.InboxPoll do
  @moduledoc """
  Per-tenant: fetch new mail from the tenant's Florina mailbox and ingest it as
  context. Skips tenants without IMAP configured. Mail errors are logged, not
  retried, so a flaky mailbox can't retry-storm.

  Args: `tenant_slug`.
  """
  use Oban.Worker, queue: :sync, max_attempts: 3, unique: [period: 120, keys: [:tenant_slug]]

  require Logger

  import Florina.Strings, only: [present?: 1]

  alias Florina.{Inbox, Settings}
  alias Florina.Inbox.InboundEmail
  alias Florina.Integrations.Imap
  alias Florina.Workers.Tenant

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_slug" => slug}}) do
    case Tenant.pin_active(slug) do
      :skip ->
        :ok

      :ok ->
        settings = Settings.get()
        if configured?(settings), do: poll(slug, settings), else: :ok
    end
  end

  defp configured?(s), do: present?(s.imap_host) and present?(s.imap_username)

  defp poll(slug, settings) do
    config = %{
      host: settings.imap_host,
      port: settings.imap_port || 993,
      username: settings.imap_username,
      password: settings.imap_password
    }

    imap = Application.get_env(:florina, :imap_client, Imap)

    case imap.fetch_new(config) do
      {:ok, messages} ->
        ingested =
          Enum.count(messages, fn msg ->
            match?({:ok, %InboundEmail{}}, Inbox.ingest(msg))
          end)

        Logger.info("[InboxPoll] tenant=#{slug} ingested=#{ingested} of #{length(messages)}")
        :ok

      {:error, :not_configured} ->
        :ok

      {:error, reason} ->
        Logger.warning("[InboxPoll] tenant=#{slug} fetch failed: #{inspect(reason)}")
        :ok
    end
  end
end
