defmodule Florina.Integrations.ElevenLabs do
  @moduledoc """
  ElevenLabs Conversational AI outbound API client.

  Behaviour callbacks:
  - `initiate_call/4` — start an outbound call via the Twilio bridge.
  - `get_conversation/1` — fetch raw conversation data (status, transcript, etc.).
  - `fetch_transcript/1` — fetch and format the transcript for a conversation.

  The implementation is chosen via:

      config :florina, :elevenlabs_client, Florina.Integrations.ElevenLabs

  Tests swap in `Florina.Integrations.ElevenLabs.Stub`.

  Auth: global `xi-api-key` from `config :florina, :elevenlabs_api_key`.
  Required config keys also include `:elevenlabs_agent_id` and
  `:elevenlabs_phone_number_id`.

  Deferred from the Django source (not needed for the core call path):
  - `format_prompt_for_visit/3` (Romanian token substitution) — the Elixir
    prompt assembler in `Florina.Services.PromptAssembler` handles this.
  - `sync_call_status_from_api/1` (status polling fallback) — will be an
    Oban worker in Backend Phase 4.
  - Agent-level webhook config endpoints (placeholder in Django; not wired up).
  """

  @callback initiate_call(String.t(), String.t(), String.t() | nil, map()) ::
              {:ok, %{call_id: String.t()}} | {:error, term()}

  @callback get_conversation(String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback fetch_transcript(String.t()) ::
              {:ok, String.t() | nil} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Resolve the configured implementation (real or stub).
  # ---------------------------------------------------------------------------

  @doc false
  def impl do
    Application.get_env(:florina, :elevenlabs_client, __MODULE__)
  end

  @doc """
  Initiate an outbound call.

  - `to_number`: E.164 phone number to call.
  - `prompt`: System-prompt text (sent as an override if non-empty).
  - `first_message`: First-message override (optional).
  - `context`: Additional context map for tracing / logging (ignored by HTTP impl).
  """
  def initiate_call(to_number, prompt, first_message, context \\ %{}),
    do: impl().do_initiate_call(to_number, prompt, first_message, context)

  @doc "Fetch raw conversation data from ElevenLabs."
  def get_conversation(conversation_id),
    do: impl().do_get_conversation(conversation_id)

  @doc "Fetch and format the transcript text for a conversation. Returns `{:ok, text | nil}`."
  def fetch_transcript(conversation_id),
    do: impl().do_fetch_transcript(conversation_id)

  # ---------------------------------------------------------------------------
  # Real implementation (do_* names avoid collision with delegating API above).
  # ---------------------------------------------------------------------------

  @base_url "https://api.elevenlabs.io/v1"
  @convai_url "#{@base_url}/convai"

  @doc false
  def do_initiate_call(to_number, prompt, first_message, _context) do
    with {:ok, api_key} <- get_config(:elevenlabs_api_key),
         {:ok, agent_id} <- get_config(:elevenlabs_agent_id),
         {:ok, phone_number_id} <- get_config(:elevenlabs_phone_number_id) do
      payload = build_call_payload(agent_id, phone_number_id, to_number, prompt, first_message)

      case Req.post("#{@convai_url}/twilio/outbound-call",
             headers: headers(api_key),
             json: payload,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: body}} ->
          call_id =
            body["conversation_id"] || body["call_id"] || body["id"] || body["call_sid"]

          if call_id do
            {:ok, %{call_id: call_id}}
          else
            {:error, {:no_call_id, body}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, extract_error(body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  def do_get_conversation(conversation_id) do
    with {:ok, api_key} <- get_config(:elevenlabs_api_key) do
      # Try endpoints in priority order; ElevenLabs has been inconsistent across versions.
      endpoints = [
        "#{@convai_url}/conversations/#{conversation_id}",
        "#{@convai_url}/calls/#{conversation_id}",
        "#{@base_url}/conversations/#{conversation_id}",
        "#{@base_url}/calls/#{conversation_id}"
      ]

      try_endpoints(endpoints, headers(api_key))
    end
  end

  @doc false
  def do_fetch_transcript(conversation_id) do
    case do_get_conversation(conversation_id) do
      {:ok, data} -> {:ok, parse_transcript(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp headers(api_key) do
    [{"xi-api-key", api_key}, {"content-type", "application/json"}]
  end

  defp get_config(key) do
    case Application.get_env(:florina, key) do
      nil -> {:error, {:missing_config, key}}
      "" -> {:error, {:missing_config, key}}
      val -> {:ok, val}
    end
  end

  defp build_call_payload(agent_id, phone_number_id, to_number, prompt, first_message) do
    base = %{
      "agent_id" => agent_id,
      "agent_phone_number_id" => phone_number_id,
      "to_number" => to_number
    }

    if prompt && String.trim(prompt) != "" do
      agent_config =
        %{"prompt" => %{"prompt" => String.trim(prompt)}}
        |> then(fn cfg ->
          if first_message && String.trim(first_message) != "" do
            Map.put(cfg, "first_message", String.trim(first_message))
          else
            cfg
          end
        end)

      Map.put(base, "conversation_initiation_client_data", %{
        "conversation_config_override" => %{"agent" => agent_config}
      })
    else
      base
    end
  end

  defp try_endpoints([], _headers), do: {:error, :not_found}

  defp try_endpoints([url | rest], headers) do
    case Req.get(url, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        try_endpoints(rest, headers)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, extract_error(body)}}

      {:error, _reason} ->
        try_endpoints(rest, headers)
    end
  end

  # Parse transcript from a raw ElevenLabs conversation response.
  # Returns a formatted "Role: message\n\nRole: message" string, or nil.
  defp parse_transcript(data) when is_map(data) do
    transcript_raw =
      data["transcript"] ||
        data["conversation_transcript"] ||
        (is_map(data["data"]) && data["data"]["transcript"])

    case transcript_raw do
      nil -> nil
      list when is_list(list) -> format_turns(list)
      %{"turns" => turns} when is_list(turns) -> format_turns(turns)
      %{} = m -> m["text"] || m["content"] || m["transcript"]
      str when is_binary(str) -> str
      other -> inspect(other)
    end
  end

  defp parse_transcript(_), do: nil

  defp format_turns(turns) do
    lines =
      Enum.flat_map(turns, fn turn ->
        if is_map(turn) do
          role = turn["role"] || "unknown"
          message = turn["message"] || turn["content"] || turn["text"]

          if message do
            label =
              case role do
                "agent" -> "Agent"
                "user" -> "User"
                other -> String.capitalize(other)
              end

            ["#{label}: #{message}"]
          else
            []
          end
        else
          []
        end
      end)

    if lines == [], do: nil, else: Enum.join(lines, "\n\n")
  end

  defp extract_error(body) when is_map(body) do
    body["detail"] || body["message"] || body["error"] || inspect(body)
  end

  defp extract_error(body), do: inspect(body)
end
