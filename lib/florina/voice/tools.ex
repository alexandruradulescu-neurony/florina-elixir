defmodule Florina.Voice.Tools do
  @moduledoc """
  Business logic for the inbound concierge's mid-call server tools.

  All three are scoped to the CALLER's own agent id (passed in from the tool
  request, bound to the `{{agent_id}}` dynamic variable set during personalize):
  Florina can never reach another agent's meetings.

  - `find_meeting/3`    — fuzzy-resolve a spoken meeting/client to candidates.
  - `get_call_script/3` — the pre/post briefing for a meeting (generated on demand).
  - `save_outcome/5`    — record the briefing outcome + advance the meeting's status.
  """
  import Ecto.Query, only: [from: 2]
  require Logger

  alias Florina.{Audit, Clients, Emails, TenantRepo, Visits}
  alias Florina.Visits.Visit
  alias Florina.Calls.CallAttempt
  alias Florina.Services.Assembler
  alias Florina.Workers.SendEmail

  @window_seconds 7 * 24 * 3600
  @score_floor 0.55

  # ---------------------------------------------------------------------------
  # find_meeting
  # ---------------------------------------------------------------------------

  @doc """
  Returns up to 3 of the caller's meetings ranked against `query` (client name or
  title, diacritic-insensitive). Empty when nothing clears the score floor —
  never a single blind guess.
  """
  def find_meeting(agent_id, query, _phase \\ nil) do
    with aid when is_integer(aid) <- to_int(agent_id),
         q when q != "" <- normalize_for_match(query) do
      now = DateTime.utc_now()

      aid
      |> search_window(now)
      |> Enum.map(fn v -> {v, score(q, v)} end)
      |> Enum.filter(fn {_v, s} -> s >= @score_floor end)
      |> Enum.sort_by(fn {_v, s} -> s end, :desc)
      |> Enum.take(3)
      |> Enum.map(fn {v, s} -> candidate_map(v, s, now) end)
    else
      _ -> []
    end
  end

  defp search_window(agent_id, now) do
    from_t = DateTime.add(now, -@window_seconds, :second)
    to_t = DateTime.add(now, @window_seconds, :second)

    from(v in Visit,
      where:
        v.agent_id == ^agent_id and
          v.start_time >= ^from_t and v.start_time <= ^to_t and
          v.status not in [:CANCELLED, :COMPLETE, :ARCHIVED],
      preload: [:client],
      limit: 50
    )
    |> TenantRepo.all()
  end

  defp score(q, visit) do
    name = normalize_for_match(client_name(visit))
    title = normalize_for_match(visit.title)
    Enum.max([field_score(q, name), field_score(q, title)])
  end

  defp field_score(_q, ""), do: 0.0

  defp field_score(q, field) do
    if String.contains?(field, q) do
      1.0
    else
      # Compare against the whole field AND each token, so a spoken client name
      # still matches when the record carries a suffix ("Ionescu" vs "Ionescu SRL").
      token_best =
        field
        |> String.split()
        |> Enum.map(&String.jaro_distance(q, &1))
        |> Enum.max(fn -> 0.0 end)

      max(String.jaro_distance(q, field), token_best)
    end
  end

  defp candidate_map(v, score, now) do
    %{
      "visit_id" => v.id,
      "title" => v.title,
      "client" => client_name(v),
      "start_time" => v.start_time && DateTime.to_iso8601(v.start_time),
      "phase_state" => phase_for(v.start_time, now),
      "score" => Float.round(score, 3)
    }
  end

  # ---------------------------------------------------------------------------
  # get_call_script
  # ---------------------------------------------------------------------------

  @doc """
  Returns the briefing/debrief script for a meeting, generating it via the
  assembler if it doesn't exist yet. `{:ok, %{"script","first_line","generated"}}`
  or `{:error, :not_found | :bad_phase}`.
  """
  def get_call_script(agent_id, visit_id, phase) when phase in ["pre", "post"] do
    case owned_visit(agent_id, visit_id) do
      %Visit{} = visit ->
        {script, first_line, generated} = ensure_script(visit, phase)
        {:ok, %{"script" => script, "first_line" => first_line, "generated" => generated}}

      nil ->
        {:error, :not_found}
    end
  end

  def get_call_script(_agent_id, _visit_id, _phase), do: {:error, :bad_phase}

  defp ensure_script(%Visit{pre_call_prompt: p, pre_call_first_message: f} = _v, "pre")
       when is_binary(p) and p != "" do
    {p, f || "", false}
  end

  defp ensure_script(%Visit{post_call_prompt: p, post_call_first_message: f} = _v, "post")
       when is_binary(p) and p != "" do
    {p, f || "", false}
  end

  defp ensure_script(visit, "pre") do
    Assembler.assemble_pre_call(visit)
    v = Visits.get!(visit.id)
    {v.pre_call_prompt || "", v.pre_call_first_message || "", true}
  end

  defp ensure_script(visit, "post") do
    Assembler.assemble_post_call(visit, "")
    v = Visits.get!(visit.id)
    {v.post_call_prompt || "", v.post_call_first_message || "", true}
  end

  # ---------------------------------------------------------------------------
  # save_outcome
  # ---------------------------------------------------------------------------

  @doc """
  Records the briefing outcome as a CallAttempt on THIS meeting, advances the
  meeting's status, and audit-logs it. `{:ok, %{"ok" => true, "new_status" => ...}}`
  or `{:error, :not_found | :bad_phase}`. Explicit `visit_id` — one call may touch
  several meetings, each attributed to its own record.
  """
  def save_outcome(agent_id, visit_id, phase, summary, notes \\ nil)

  def save_outcome(agent_id, visit_id, phase, summary, notes) when phase in ["pre", "post"] do
    case owned_visit(agent_id, visit_id) do
      %Visit{} = visit ->
        {:ok, _ca} =
          %CallAttempt{}
          |> CallAttempt.create_changeset(%{
            visit_id: visit.id,
            phase: String.upcase(phase),
            status: "COMPLETED",
            summary: summary || "",
            analysis: %{"source" => "inbound_concierge", "notes" => notes}
          })
          |> TenantRepo.insert()

        new_status = advance_status(visit, phase)

        Audit.log(%{
          action: "voice.save_outcome",
          visit_id: visit.id,
          user_id: to_int(agent_id),
          details: %{"phase" => String.upcase(phase)}
        })

        {:ok, %{"ok" => true, "new_status" => to_string(new_status)}}

      nil ->
        {:error, :not_found}
    end
  end

  def save_outcome(_agent_id, _visit_id, _phase, _summary, _notes), do: {:error, :bad_phase}

  defp advance_status(%Visit{status: :PLANNED} = visit, "pre"), do: bump(visit, :PRE_CALL_DONE)
  defp advance_status(%Visit{status: status}, "pre"), do: status

  defp advance_status(%Visit{status: status} = visit, "post")
       when status in [:IN_PROGRESS, :PRE_CALL_DONE, :PLANNED],
       do: bump(visit, :POST_CALL_DONE)

  defp advance_status(%Visit{status: status}, "post"), do: status

  defp bump(visit, status) do
    case Visits.update(visit, %{status: status}) do
      {:ok, v} -> v.status
      _ -> visit.status
    end
  end

  # ---------------------------------------------------------------------------
  # draft_or_send_email
  # ---------------------------------------------------------------------------

  @doc """
  Queues a follow-up email to a client from an approved template. The recipient is
  resolved server-side from the client's contacts (never model-supplied) and the
  actual send happens in a background job. `{:ok, %{"ok" => true, "mode" => "queued"}}`
  or `{:error, :bad_purpose | :not_found | :no_recipient}`.
  """
  def draft_or_send_email(tenant_slug, agent_id, client_id, purpose, notes \\ nil) do
    cond do
      purpose not in Emails.purposes() ->
        {:error, :bad_purpose}

      is_nil(to_int(client_id)) ->
        {:error, :not_found}

      true ->
        case Clients.get(to_int(client_id)) do
          nil ->
            {:error, :not_found}

          client ->
            resolve_and_queue(tenant_slug, agent_id, client, purpose, notes)
        end
    end
  end

  defp resolve_and_queue(tenant_slug, agent_id, client, purpose, notes) do
    case Emails.recipient_for(client) do
      nil ->
        {:error, :no_recipient}

      to ->
        %{
          "tenant_slug" => tenant_slug,
          "client_id" => client.id,
          "to" => to,
          "purpose" => purpose,
          "notes" => notes,
          "agent_id" => to_int(agent_id)
        }
        |> SendEmail.new()
        |> Oban.insert()

        Audit.log(%{
          action: "voice.email_queued",
          user_id: to_int(agent_id),
          details: %{"client_id" => client.id, "purpose" => purpose}
        })

        {:ok, %{"ok" => true, "mode" => "queued"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Load a visit only if it belongs to this caller — the per-agent data boundary.
  defp owned_visit(agent_id, visit_id) do
    with aid when is_integer(aid) <- to_int(agent_id),
         vid when is_integer(vid) <- to_int(visit_id),
         %Visit{agent_id: ^aid} = visit <- Visits.get(vid) do
      visit
    else
      _ -> nil
    end
  end

  defp phase_for(nil, _now), do: "pre"

  defp phase_for(start_time, now) do
    if DateTime.compare(start_time, now) == :lt, do: "post", else: "pre"
  end

  defp client_name(%Visit{client: %{name: name}}) when is_binary(name), do: name
  defp client_name(_), do: ""

  # Downcase + strip diacritics (ă â î ș ț etc.) via NFD, so "Ionesku" ~ "Ionescu".
  defp normalize_for_match(nil), do: ""

  defp normalize_for_match(s) when is_binary(s) do
    s
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.trim()
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
