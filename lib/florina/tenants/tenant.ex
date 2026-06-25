defmodule Florina.Tenants.Tenant do
  @moduledoc "A tenant in the control-plane registry: which database is theirs."
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(provisioning active failed)

  schema "tenants" do
    field :slug, :string
    field :name, :string
    field :database, :string
    field :active, :boolean, default: true
    field :status, :string, default: "active"
    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name, :database, :active, :status])
    |> validate_required([:slug, :name, :database])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:slug)
  end
end
