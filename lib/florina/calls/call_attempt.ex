defmodule Florina.Calls.CallAttempt do
  @moduledoc "Maps Django's existing `voice_callattempt` table (shared schema)."
  use Ecto.Schema
  import Ecto.Changeset

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
  end
end
