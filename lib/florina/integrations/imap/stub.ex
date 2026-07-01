defmodule Florina.Integrations.Imap.Stub do
  @moduledoc """
  Test double for `Florina.Integrations.Imap`. Returns whatever messages the test
  put in `:imap_stub_messages` app env, so the inbox pipeline + poll worker can be
  exercised without a real mailbox.
  """
  @behaviour Florina.Integrations.Imap

  @impl true
  def fetch_new(_config) do
    {:ok, Application.get_env(:florina, :imap_stub_messages, [])}
  end
end
