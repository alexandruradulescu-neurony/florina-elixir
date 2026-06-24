defmodule Florina.Tenants.Marker do
  @moduledoc """
  Throwaway proof-of-isolation table; one of these lives in EACH tenant
  database. Used by the leakage test and the /whoami diagnostic page.
  Remove once real per-tenant consumers are wired.
  """
  use Ecto.Schema

  schema "tenant_markers" do
    field :label, :string
    timestamps(type: :utc_datetime)
  end
end
