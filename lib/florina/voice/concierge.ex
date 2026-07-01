defmodule Florina.Voice.Concierge do
  @moduledoc """
  Builds the response for the inbound "personalize" (pre-connect) webhook that
  ElevenLabs calls during the ring.

  Given the caller's number and the resolved tenant, it identifies the agent,
  gathers the meetings they might be calling about, and returns ElevenLabs'
  `conversation_config_override` + `dynamic_variables` so Florina opens the call
  knowing who she's talking to and what's on their plate.

  Phase 1 scope: identification + a tailored greeting + candidate meetings. The
  conductor prompt here is the base version; the mid-call tools (`find_meeting`,
  `get_call_script`, `save_outcome`) and the tool-usage instructions arrive in a
  later phase.
  """
  require Logger

  alias Florina.{Accounts, Visits}

  # ElevenLabs recognition + speech language for this deployment (Romanian).
  @language "ro"

  @doc """
  Build the personalization payload for a caller. `params` is the string-keyed
  webhook body (expects `"caller_id"`). Always returns a response — an
  unrecognized caller gets a generic greeting that asks who's calling.
  """
  def personalize(params, _tenant) when is_map(params) do
    caller_id = params["caller_id"] || params["caller_number"] || params["from"]

    case Accounts.get_agent_by_phone(caller_id) do
      nil ->
        Logger.warning("[Voice] unrecognized caller #{mask(caller_id)}")
        unknown_caller_response()

      agent ->
        known_caller_response(agent)
    end
  end

  # --- Response builders -----------------------------------------------------

  defp known_caller_response(agent) do
    name = agent.first_name || agent.username
    candidates = Visits.concierge_candidates(agent.id)

    payload(
      prompt: conductor_prompt(name),
      first_message: "Bună ziua, #{name}! Sunt Florina. Despre care întâlnire vă pot ajuta?",
      dynamic_variables: %{
        "agent_name" => name,
        "agent_id" => to_string(agent.id),
        "candidate_meetings" => format_candidates(candidates)
      }
    )
  end

  defp unknown_caller_response do
    payload(
      prompt: conductor_prompt_unknown(),
      first_message: "Bună ziua! Sunt Florina. Cu cine vorbesc, vă rog?",
      dynamic_variables: %{"agent_name" => "", "candidate_meetings" => ""}
    )
  end

  defp payload(opts) do
    %{
      "conversation_config_override" => %{
        "agent" => %{
          "prompt" => %{"prompt" => Keyword.fetch!(opts, :prompt)},
          "first_message" => Keyword.fetch!(opts, :first_message),
          "language" => @language
        }
      },
      "dynamic_variables" => Keyword.fetch!(opts, :dynamic_variables)
    }
  end

  # --- Prompts ---------------------------------------------------------------

  # Instructions are in English (the model follows them reliably); the CONVERSATION
  # is Romanian, set via `language` and reinforced here.
  defp conductor_prompt(name) do
    """
    You are Florina, a sales assistant. Speak Romanian, naturally and concisely.
    #{name} is calling between meetings to catch up on the pre-call and post-call
    briefings they missed.

    Your job:
    1. Confirm which meeting they mean, using the candidate list, and whether they
       want the pre-call (before the meeting) or the post-call (after it).
    2. Run the right briefing for that meeting.
    3. When done, ask whether there's another meeting to cover.

    Possible meetings: {{candidate_meetings}}

    Never invent information. If you are unsure which meeting they mean, ask for the
    client name or the meeting time.
    """
  end

  defp conductor_prompt_unknown do
    """
    You are Florina, a sales assistant. Speak Romanian, naturally and concisely.
    You could not recognize this caller's number, so first find out who they are:
    ask for their name and, if helpful, the client or meeting time. Do not reveal
    any client or meeting information until you know who you are speaking with.
    """
  end

  # --- Formatting ------------------------------------------------------------

  defp format_candidates([]), do: "(nicio întâlnire recentă)"

  defp format_candidates(candidates) do
    now = DateTime.utc_now()

    Enum.map_join(candidates, "; ", fn v ->
      client = if v.client, do: v.client.name, else: "client necunoscut"
      phase = if DateTime.compare(v.start_time, now) == :lt, do: "post-call", else: "pre-call"
      time = Calendar.strftime(v.start_time, "%d %b %H:%M")
      "#{v.title} cu #{client} la #{time} (#{phase})"
    end)
  end

  # Log only the last 4 digits of an unrecognized number.
  defp mask(nil), do: "(no caller id)"

  defp mask(number) when is_binary(number) do
    tail = number |> String.replace(~r/\D/, "") |> String.slice(-4, 4)
    "***#{tail}"
  end

  defp mask(_), do: "(no caller id)"
end
