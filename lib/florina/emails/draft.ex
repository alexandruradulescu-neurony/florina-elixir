defmodule Florina.Emails.Draft do
  @moduledoc """
  A concierge follow-up email queued for sending. Persisted in the TENANT schema
  so the recipient address, dictated notes and meeting/client labels stay out of
  the shared public `oban_jobs` args — the `SendEmail` job carries only this
  draft's id + the tenant slug.

  Table: `voice_email_draft`
  """
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "voice_email_draft" do
    field :recipient, :string
    field :purpose, :string
    field :notes, :string
    field :client_name, :string
    field :meeting_title, :string
    field :meeting_time, :string
    field :agent_id, :integer
    field :visit_id, :integer
    field :client_id, :integer

    timestamps()
  end

  @fields [
    :recipient,
    :purpose,
    :notes,
    :client_name,
    :meeting_title,
    :meeting_time,
    :agent_id,
    :visit_id,
    :client_id
  ]

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, @fields)
    |> validate_required([:recipient, :purpose])
  end
end
