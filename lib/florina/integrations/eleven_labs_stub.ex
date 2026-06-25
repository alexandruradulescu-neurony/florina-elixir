defmodule Florina.Integrations.ElevenLabs.Stub do
  @moduledoc """
  Test stub for `Florina.Integrations.ElevenLabs`.

  Responses are controlled via the process dictionary so individual tests can
  set their own expectations without global state.

  Usage:

      # Return a successful call initiation
      Florina.Integrations.ElevenLabs.Stub.set_initiate_call({:ok, %{call_id: "conv_abc123"}})

      # Make get_conversation return a canned response
      Florina.Integrations.ElevenLabs.Stub.set_get_conversation({:ok, %{"status" => "done", "transcript" => []}})

      # Default (no setup) returns success responses with fake IDs.

  Configured in test.exs:

      config :florina, :elevenlabs_client, Florina.Integrations.ElevenLabs.Stub
  """

  # The dispatch pattern in ElevenLabs calls do_* on the resolved impl module.

  @default_call_id "conv_stub_test_001"

  def do_initiate_call(_to_number, _prompt, _first_message, _context) do
    Process.get(:el_stub_initiate_call, {:ok, %{call_id: @default_call_id}})
  end

  def do_get_conversation(_conversation_id) do
    Process.get(:el_stub_get_conversation, {:ok, %{"status" => "done", "transcript" => []}})
  end

  def do_fetch_transcript(_conversation_id) do
    Process.get(:el_stub_fetch_transcript, {:ok, nil})
  end

  # ---------------------------------------------------------------------------
  # Helpers for tests
  # ---------------------------------------------------------------------------

  def set_initiate_call(response), do: Process.put(:el_stub_initiate_call, response)
  def set_get_conversation(response), do: Process.put(:el_stub_get_conversation, response)
  def set_fetch_transcript(response), do: Process.put(:el_stub_fetch_transcript, response)

  def reset do
    Process.delete(:el_stub_initiate_call)
    Process.delete(:el_stub_get_conversation)
    Process.delete(:el_stub_fetch_transcript)
  end
end
