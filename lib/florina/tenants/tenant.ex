defmodule Florina.Tenants.Tenant do
  @moduledoc "A tenant in the control-plane registry: which database is theirs."
  use Ecto.Schema
  import Ecto.Changeset

  schema "tenants" do
    field :slug, :string
    field :name, :string
    field :database, :string
    field :active, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name, :database, :active])
    |> validate_required([:slug, :name, :database])
    |> unique_constraint(:slug)
  end
end
