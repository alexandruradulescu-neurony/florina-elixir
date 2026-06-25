defmodule Florina.Visits.Visit do
  @moduledoc """
  Central entity tying together agent, client, calendar event, calls and CRM deal.

  Table: `voice_visit`
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Florina.Enums

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_visit" do
    belongs_to :agent, Florina.Accounts.User
    belongs_to :client, Florina.Clients.Client
    belongs_to :methodology, Florina.Methodologies.Methodology
    belongs_to :scenario, Florina.Scenarios.Scenario

    has_many :call_attempts, Florina.Calls.CallAttempt

    field :calendar_event_id, :string
    # Which calendar the event came from (:google | :microsoft). Lets calendar
    # sync match events per-provider so a Google and a Microsoft event id can't
    # collide on the same visit. Null for manually-created visits.
    field :provider, Ecto.Enum, values: [:google, :microsoft]
    field :title, :string
    field :start_time, :utc_datetime
    field :end_time, :utc_datetime
    field :attendees, {:array, :map}, default: []
    field :crm_deal_id, :string
    field :manager_notes, :string

    field :status, Ecto.Enum, values: Enums.visit_status_values(), default: :PLANNED

    field :pre_call_prompt, :string
    field :pre_call_first_message, :string, default: ""
    field :post_call_prompt, :string
    field :post_call_first_message, :string, default: ""

    field :pre_call_prompt_locked, :boolean, default: false
    field :pre_call_first_message_locked, :boolean, default: false
    field :post_call_prompt_locked, :boolean, default: false
    field :post_call_first_message_locked, :boolean, default: false

    field :post_call_summary, :string
    field :crm_synced, :boolean, default: false

    timestamps()
  end

  @required_fields [:agent_id, :client_id, :title, :start_time, :end_time]
  @optional_fields [
    :calendar_event_id,
    :provider,
    :attendees,
    :crm_deal_id,
    :manager_notes,
    :methodology_id,
    :scenario_id,
    :status,
    :pre_call_prompt,
    :pre_call_first_message,
    :post_call_prompt,
    :post_call_first_message,
    :pre_call_prompt_locked,
    :pre_call_first_message_locked,
    :post_call_prompt_locked,
    :post_call_first_message_locked,
    :post_call_summary,
    :crm_synced
  ]

  @doc "Changeset for creating/updating a visit."
  def changeset(visit, attrs) do
    visit
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:title, max: 255)
    |> validate_length(:calendar_event_id, max: 255)
    |> validate_length(:crm_deal_id, max: 100)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:client_id)
    |> foreign_key_constraint(:methodology_id)
    |> foreign_key_constraint(:scenario_id)
    # Backstop against concurrent calendar syncs creating the same visit twice.
    # Error attributed to :calendar_event_id so CalendarSync can detect the race.
    |> unique_constraint(:calendar_event_id, name: :voice_visit_agent_provider_event_uidx)
  end
end
