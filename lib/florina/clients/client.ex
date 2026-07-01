defmodule Florina.Clients.Client do
  @moduledoc """
  Client/company synced from CRM. Local copy for AI enrichment.

  Table: `voice_client`
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Florina.Enums
  alias Florina.Strings

  @timestamps_opts [type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at]

  schema "voice_client" do
    field :crm_id, :string
    field :name, :string
    field :domain, :string
    field :industry, :string
    # stored "nou" or "existent" (Romanian) — matches Django ClientStatus
    field :status, Ecto.Enum, values: Enums.client_status_values(), default: :new
    field :contacts, {:array, :map}, default: []
    field :deal_history, {:array, :map}, default: []
    field :interaction_history, {:array, :map}, default: []
    field :ai_summary, :string
    field :lessons_learned, :string, default: ""
    field :raw_data, :map, default: %{}
    field :last_synced_at, :utc_datetime

    timestamps()
  end

  @required_fields [:name]
  @optional_fields [
    :crm_id,
    :domain,
    :industry,
    :status,
    :contacts,
    :deal_history,
    :interaction_history,
    :ai_summary,
    :lessons_learned,
    :raw_data,
    :last_synced_at
  ]

  @doc """
  Changeset for creating/updating a client record.

  Only `name` is caller-required. CRM- and calendar-synced clients bring their own
  `crm_id`; a manually-added client can omit it and gets a generated `manual:<id>`
  (`ensure_crm_id/1`), keeping the column unique and non-null. `domain` is
  canonicalised via `normalize_domain/1` so case / `www.` variants match one row.
  """
  def changeset(client, attrs) do
    client
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> update_change(:crm_id, &Strings.blank_to_nil/1)
    |> ensure_crm_id()
    |> update_change(:domain, &normalize_domain/1)
    |> validate_required(@required_fields)
    |> validate_length(:crm_id, max: 100)
    |> validate_length(:name, max: 255)
    |> validate_length(:domain, max: 255)
    |> unique_constraint(:crm_id)
  end

  # A manually-added client may arrive with a blank crm_id. Keep the column
  # non-null + unique by minting a synthetic "manual:<uuid>", mirroring the
  # calendar sync's "auto:<domain>". CRM- and calendar-sourced clients keep theirs.
  defp ensure_crm_id(changeset) do
    case get_field(changeset, :crm_id) do
      blank when blank in [nil, ""] ->
        put_change(changeset, :crm_id, "manual:" <> Ecto.UUID.generate())

      _ ->
        changeset
    end
  end

  @doc """
  Canonicalises a domain for storage and matching: trims, lowercases, and drops a
  pasted scheme, path, `@` local-part, and a leading `www.`. Blank → `nil`. Does not
  collapse subdomains (no public-suffix list), so `mail.acme.com` stays distinct.

      normalize_domain("WWW.Acme.com")     #=> "acme.com"
      normalize_domain("https://acme.com/") #=> "acme.com"
      normalize_domain("joe@acme.com")      #=> "acme.com"
  """
  def normalize_domain(value) when is_binary(value) do
    host =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("https://", "")

    host =
      case String.split(host, "@") do
        [_local, dom] -> dom
        _ -> host
      end

    host
    |> String.split("/", parts: 2)
    |> List.first()
    |> String.replace_prefix("www.", "")
    |> String.trim()
    |> case do
      "" -> nil
      d -> d
    end
  end

  def normalize_domain(_), do: nil
end
