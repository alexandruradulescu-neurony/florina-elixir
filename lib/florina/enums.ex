defmodule Florina.Enums do
  @moduledoc """
  Shared enum value lists used across multiple Ecto schemas.

  Ecto.Enum is declared on each schema; this module centralises the
  canonical value lists so they can be referenced in changeset
  validations, tests, and documentation without importing the full schema.

  Stored values match Django's TextChoices exactly.
  """

  @doc "Call phase — stored as \"PRE\" or \"POST\" in the DB."
  def call_phase_values, do: [PRE: "PRE", POST: "POST"]

  @doc "Call status values."
  def call_status_values,
    do: [
      SCHEDULED: "SCHEDULED",
      INITIATED: "INITIATED",
      IN_PROGRESS: "IN_PROGRESS",
      COMPLETED: "COMPLETED",
      NO_ANSWER: "NO_ANSWER",
      FAILED: "FAILED"
    ]

  @doc "Visit lifecycle status values."
  def visit_status_values,
    do: [
      PLANNED: "PLANNED",
      PRE_CALL_DONE: "PRE_CALL_DONE",
      IN_PROGRESS: "IN_PROGRESS",
      POST_CALL_DONE: "POST_CALL_DONE",
      COMPLETE: "COMPLETE"
    ]

  @doc "Client relationship status — stored in Romanian (\"nou\"/\"existent\")."
  def client_status_values, do: [new: "nou", existing: "existent"]

  @doc "Activity log severity levels."
  def log_level_values,
    do: [
      DEBUG: "DEBUG",
      INFO: "INFO",
      WARNING: "WARNING",
      ERROR: "ERROR",
      CRITICAL: "CRITICAL"
    ]

  @doc "MegaPrompt assembler domain values."
  def mega_prompt_domain_values,
    do: [
      PRE_CALL: "PRE_CALL",
      POST_CALL: "POST_CALL",
      LESSONS_DISTILL: "LESSONS_DISTILL"
    ]

  @doc "GenerationRun trigger source values."
  def triggered_by_values,
    do: [
      MANUAL: "MANUAL",
      SCHEDULED: "SCHEDULED",
      END_OF_MEETING: "END_OF_MEETING"
    ]
end
