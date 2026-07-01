defmodule Florina.Integrations.Imap do
  @moduledoc """
  Transport for reading the tenant's Florina mailbox over IMAP.

  Behaviour + swappable implementation (like the ElevenLabs / CRM clients), chosen
  via `:imap_client` config so tests use `Florina.Integrations.Imap.Stub`.

  `fetch_new/1` takes the tenant's IMAP config (`%{host, port, username, password}`)
  and returns newly-arrived messages as parsed maps:

      {:ok, [%{message_id, from_email, from_name, subject, body, received_at}]}
      | {:error, reason}

  The rest of the inbox pipeline (`Florina.Inbox`, the poll worker, the read tool)
  is built and tested against this behaviour. The real network fetch is the single
  piece that needs a live mailbox to finalise — there's no clean one-shot IMAP
  library for Elixir the way `gen_smtp` covers sending — so the default real
  implementation reports `:not_configured` until it's wired up with the maintainer
  against a real mailbox.
  """

  @callback fetch_new(map()) :: {:ok, [map()]} | {:error, term()}

  require Logger

  @behaviour __MODULE__
  @impl true
  def fetch_new(_config) do
    Logger.info("[Imap] real IMAP fetch not yet wired — pipeline ready, awaiting live mailbox")
    {:error, :not_configured}
  end
end
