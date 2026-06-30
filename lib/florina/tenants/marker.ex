defmodule Florina.Tenants.Marker do
  @moduledoc """
  Proof-of-isolation table; one of these lives in each tenant schema. Used by
  the leakage test to confirm a query pinned to one tenant cannot read another
  tenant's row.
  """
  use Ecto.Schema

  schema "tenant_markers" do
    field :label, :string
    timestamps(type: :utc_datetime)
  end
end
