defmodule Florina.Services.VisitPipeline do
  @moduledoc """
  Orchestration layer that ties prompt generation to the visit lifecycle.

  Mirrors `voice/services/visit_pipeline.py` — the part that triggers
  pre/post-call assembly at the right lifecycle moments.

  Note: the Django `visit_pipeline.py` actually covers two concerns:
    1. Calendar event → Visit creation (detect_visits_for_agent).
    2. Pre/post-call prompt assembly orchestration.

  The calendar-sync part (concern 1) belongs in a future external-integrations
  slice. This module covers concern 2 only: the functions called at
  well-defined visit lifecycle transitions.

  Public API:

  - `process_pre_call/1`  — trigger pre-call prompt assembly for a visit
  - `process_post_call/2` — trigger post-call prompt assembly + lessons distill

  Both return `{:ok, results_map}` or `{:error, term}`.
  """

  require Logger

  alias Florina.Visits.Visit
  alias Florina.{Visits, Clients}
  alias Florina.Services.{Assembler, Lessons}

  # ---------------------------------------------------------------------------
  # Pre-call
  # ---------------------------------------------------------------------------

  @doc """
  Process a visit's pre-call phase:
    1. Run `Assembler.assemble_pre_call/2`.
    2. Advance visit status to `:PRE_CALL_DONE` on success (if currently `:PLANNED`).

  Returns `{:ok, %{run: run, visit: visit}}` or `{:error, term}`.
  """
  def process_pre_call(%Visit{} = visit, triggered_by \\ :SCHEDULED) do
    case Assembler.assemble_pre_call(visit, triggered_by) do
      {:ok, run} ->
        updated_visit =
          if run.success and visit.status == :PLANNED do
            case Visits.update(visit, %{status: :PRE_CALL_DONE}) do
              {:ok, v} ->
                v

              {:error, cs} ->
                Logger.warning(
                  "VisitPipeline: could not advance status to PRE_CALL_DONE: #{inspect(cs.errors)}"
                )

                visit
            end
          else
            visit
          end

        {:ok, %{run: run, visit: updated_visit}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Post-call
  # ---------------------------------------------------------------------------

  @doc """
  Process a visit's post-call phase:
    1. Run `Assembler.assemble_post_call/3`.
    2. If assembly succeeded and `post_call_summary` is present, run lessons
       distillation for the client.
    3. Advance visit status to `:POST_CALL_DONE` on successful assembly.

  `transcript` is the meeting debrief transcript (may be empty string).
  Returns `{:ok, %{run: run, lessons_run: run_or_nil, visit: visit}}` or `{:error, term}`.
  """
  def process_post_call(%Visit{} = visit, transcript \\ "", triggered_by \\ :SCHEDULED) do
    case Assembler.assemble_post_call(visit, transcript, triggered_by) do
      {:ok, run} ->
        updated_visit =
          if run.success and visit.status in [:IN_PROGRESS, :PRE_CALL_DONE, :PLANNED] do
            case Visits.update(visit, %{status: :POST_CALL_DONE}) do
              {:ok, v} ->
                v

              {:error, cs} ->
                Logger.warning(
                  "VisitPipeline: could not advance status to POST_CALL_DONE: #{inspect(cs.errors)}"
                )

                visit
            end
          else
            visit
          end

        # Run lessons distillation when we have a post-call summary
        lessons_run =
          if run.success do
            maybe_distill_lessons(updated_visit)
          else
            nil
          end

        {:ok, %{run: run, lessons_run: lessons_run, visit: updated_visit}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Lessons distillation (called from post-call)
  # ---------------------------------------------------------------------------

  defp maybe_distill_lessons(%Visit{} = visit) do
    # Re-fetch to get the freshest post_call_summary (may have been written
    # by assemble_post_call above — we stored the parsed body there, not
    # the post_call_summary field which is set elsewhere in the workflow).
    # Lessons distillation requires a client and a non-empty post_call_summary.
    fresh_visit = Visits.get!(visit.id)

    if fresh_visit.post_call_summary not in [nil, ""] do
      client =
        case fresh_visit do
          %{client: %Florina.Clients.Client{} = c} -> c
          %{client_id: id} -> Clients.get!(id)
        end

      case Lessons.distill(
             client,
             fresh_visit.post_call_summary,
             "",
             :END_OF_MEETING
           ) do
        {:ok, run} ->
          run

        {:error, reason} ->
          Logger.warning("VisitPipeline: lessons distill failed: #{inspect(reason)}")
          nil
      end
    else
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Domain helper: extract email domain
  # ---------------------------------------------------------------------------

  @doc """
  Extract the domain portion from an email address string.

  Returns the domain string or `nil` if the email is invalid.
  Mirrors `extract_domain_from_email` in Django's visit_pipeline.py.
  """
  def extract_domain_from_email(email) do
    # Shared canonical parse (lowercase, after-@, blank → nil), then a plausibility
    # gate: only accept a domain with a dot and more than 3 bytes.
    case Florina.Strings.email_domain(email) do
      domain when is_binary(domain) ->
        if String.contains?(domain, ".") and byte_size(domain) > 3, do: domain, else: nil

      _ ->
        nil
    end
  end
end
