defmodule Florina.Audit.ActivityLog do
  @moduledoc """
  Immutable audit log — tracks all system actions.

  Uses only a single `timestamp` column (no updated_at).

  Table: `voice_activitylog`
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Florina.Enums

  # ActivityLog has only `timestamp` (auto_now_add), no updated_at.
  @primary_key {:id, :id, autogenerate: true}

  schema "voice_activitylog" do
    belongs_to :visit, Florina.Visits.Visit
    belongs_to :user, Florina.Accounts.User

    field :action, :string
    field :details, :map, default: %{}
    field :level, Ecto.Enum, values: Enums.log_level_values(), default: :INFO

    field :timestamp, :utc_datetime, autogenerate: false
  end

  @required_fields [:action]
  @optional_fields [:visit_id, :user_id, :details, :level, :timestamp]

  @doc "Changeset for inserting an audit log entry."
  def changeset(log, attrs) do
    log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:action, max: 100)
    |> foreign_key_constraint(:visit_id)
    |> foreign_key_constraint(:user_id)
  end
end
