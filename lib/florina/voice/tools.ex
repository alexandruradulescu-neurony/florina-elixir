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

  alias Florina.{Accounts, Audit, Calls, Emails, TenantRepo, Visits}
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
      # Local (Bucharest) time the model reads back to the caller — not UTC.
      "start_time" => v.start_time && Florina.Tz.format(v.start_time, :datetime),
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

        # A blank script means generation failed — tell Florina rather than
        # handing her an empty "script" to improvise against.
        if blank?(script) do
          {:error, :generation_failed}
        else
          {:ok, %{"script" => script, "first_line" => first_line, "generated" => generated}}
        end

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
  def save_outcome(tenant_slug, agent_id, visit_id, phase, summary, notes \\ nil)

  def save_outcome(tenant_slug, agent_id, visit_id, phase, summary, notes)
      when phase in ["pre", "post"] do
    case owned_visit(agent_id, visit_id) do
      %Visit{} = visit ->
        up = String.upcase(phase)

        # Idempotent: ElevenLabs retries tool calls and the model may call twice.
        # Reuse an existing concierge outcome for this visit+phase instead of
        # inserting a duplicate COMPLETED attempt.
        ca =
          existing_concierge_attempt(visit.id, up) ||
            insert_outcome_attempt(visit, up, summary, notes)

        new_status = advance_status(visit, phase)

        Audit.log(%{
          action: "voice.save_outcome",
          visit_id: visit.id,
          user_id: to_int(agent_id),
          details: %{"phase" => up}
        })

        # Run the SAME post-call pipeline the outbound debrief runs (lessons
        # distillation, CRM note, visit → COMPLETE) so a debrief done by phone
        # doesn't diverge from one done by the outbound call. Oban-unique per
        # attempt, so a duplicate save_outcome can't double-run it.
        if up == "POST", do: Calls.maybe_enqueue_post_completion(ca, tenant_slug)

        {:ok, %{"ok" => true, "new_status" => to_string(new_status)}}

      nil ->
        {:error, :not_found}
    end
  end

  def save_outcome(_slug, _agent_id, _visit_id, _phase, _summary, _notes),
    do: {:error, :bad_phase}

  defp insert_outcome_attempt(visit, phase_upper, summary, notes) do
    {:ok, ca} =
      %CallAttempt{}
      |> CallAttempt.create_changeset(%{
        visit_id: visit.id,
        phase: phase_upper,
        status: "COMPLETED",
        summary: summary || "",
        analysis: %{"source" => "inbound_concierge", "notes" => notes}
      })
      |> TenantRepo.insert()

    ca
  end

  defp existing_concierge_attempt(visit_id, phase_upper) do
    from(ca in CallAttempt,
      where: ca.visit_id == ^visit_id and ca.phase == ^phase_upper and ca.status == "COMPLETED",
      order_by: [desc: ca.id]
    )
    |> TenantRepo.all()
    |> Enum.find(fn ca ->
      is_map(ca.analysis) and ca.analysis["source"] == "inbound_concierge"
    end)
  end

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
  Queues an email **to the AGENT (the caller)** about a meeting they own — a recap
  of what surfaced on the call, plus the client's materials attached. The recipient
  is the agent's own address, resolved server-side from `agent_id` (never a client,
  never model-supplied), so a wrong meeting id can't mail the wrong person.
  `visit_id` scopes which client's materials are pulled in. The actual send happens
  in a background job. `{:ok, %{"ok" => true, "mode" => "queued"}}` or
  `{:error, :bad_purpose | :smtp_not_configured | :not_found | :no_recipient | :queue_failed}`.
  """
  def draft_or_send_email(tenant_slug, agent_id, visit_id, purpose, notes \\ nil) do
    cond do
      purpose not in Emails.purposes() ->
        {:error, :bad_purpose}

      not Emails.smtp_configured?(Florina.Settings.get()) ->
        {:error, :smtp_not_configured}

      true ->
        with %Visit{} = visit <- owned_visit(agent_id, visit_id),
             %{email: to} when is_binary(to) and to != "" <- Accounts.get_user(to_int(agent_id)) do
          queue_agent_email(tenant_slug, to_int(agent_id), visit, to, purpose, notes)
        else
          %{} -> {:error, :no_recipient}
          _ -> {:error, :not_found}
        end
    end
  end

  defp queue_agent_email(tenant_slug, agent_id, visit, to, purpose, notes) do
    visit = TenantRepo.preload(visit, :client)

    args = %{
      "tenant_slug" => tenant_slug,
      "to" => to,
      "purpose" => purpose,
      "notes" => notes,
      "agent_id" => agent_id,
      "visit_id" => visit.id,
      "client_id" => visit.client_id,
      "client_name" => visit.client && visit.client.name,
      "meeting_title" => visit.title,
      "meeting_time" => visit.start_time && Florina.Tz.format(visit.start_time, :datetime)
    }

    case args |> SendEmail.new() |> Oban.insert() do
      {:ok, _job} ->
        Audit.log(%{
          action: "voice.email_queued",
          user_id: agent_id,
          details: %{"visit_id" => visit.id, "purpose" => purpose}
        })

        {:ok, %{"ok" => true, "mode" => "queued"}}

      {:error, _reason} ->
        {:error, :queue_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # check_client_email (read-only)
  # ---------------------------------------------------------------------------

  @doc """
  Recent ingested emails from a client, for Florina to read out mid-call. Read-only
  — never acts on the content. `{:ok, %{"emails" => [...]}}` or `{:error, :not_found}`.
  """
  def check_client_email(agent_id, visit_id) do
    # Scope to the client of a meeting the caller owns — an agent can't read
    # another client's inbox by passing an arbitrary id.
    case owned_visit(agent_id, visit_id) do
      %Visit{client_id: cid} when not is_nil(cid) ->
        emails = cid |> Florina.Inbox.recent_for_client() |> Enum.map(&email_map/1)
        {:ok, %{"emails" => emails}}

      _ ->
        {:error, :not_found}
    end
  end

  defp email_map(e) do
    %{
      "from" => e.from_email,
      "received_at" => e.received_at && DateTime.to_iso8601(e.received_at),
      "summary" => e.summary || e.subject,
      "relevant_visit_id" => e.visit_id
    }
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

  defp blank?(s), do: is_nil(s) or String.trim(to_string(s)) == ""
end
