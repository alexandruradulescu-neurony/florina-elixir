defmodule Florina.Calls.CallAttempt do
  @moduledoc "Maps Django's existing `voice_callattempt` table (shared schema)."
  use Ecto.Schema
  import Ecto.Changeset

  alias Florina.Enums

  @status_values Enum.map(Enums.call_status_values(), fn {_k, v} -> v end)
  @phase_values Enum.map(Enums.call_phase_values(), fn {_k, v} -> v end)

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_callattempt" do
    belongs_to :visit, Florina.Visits.Visit
    field :phase, :string
    field :external_call_id, :string
    field :status, :string
    field :recording_url, :string
    field :transcript, :string
    field :summary, :string
    field :summary_title, :string
    field :analysis, :map, default: %{}
    timestamps()
  end

  @doc "Fields the webhook edge is allowed to write."
  def webhook_changeset(call_attempt, attrs) do
    call_attempt
    |> cast(attrs, [
      :external_call_id,
      :status,
      :phase,
      :transcript,
      :summary,
      :summary_title,
      :analysis
    ])
    |> validate_required([:status])
    |> validate_inclusion(:status, @status_values)
    |> validate_inclusion(:phase, @phase_values)
  end

  @doc "Changeset for creating a new CallAttempt row (used by Oban workers)."
  def create_changeset(call_attempt, attrs) do
    call_attempt
    |> cast(attrs, [
      :visit_id,
      :phase,
      :status,
      :external_call_id,
      :transcript,
      :summary,
      :summary_title,
      :analysis
    ])
    |> validate_required([:visit_id, :phase, :status])
    |> validate_inclusion(:status, @status_values)
    |> validate_inclusion(:phase, @phase_values)
    |> foreign_key_constraint(:visit_id)
  end
end
