defmodule Florina.Tenants do
  @moduledoc "Control-plane registry of tenants and which database each one lives in."
  import Ecto.Query, only: [from: 2]
  alias Florina.Repo
  alias Florina.Tenants.Tenant

  def list, do: Repo.all(from t in Tenant, order_by: t.slug)

  def get_by_slug(slug) when is_binary(slug), do: Repo.get_by(Tenant, slug: slug)
  def get_by_slug(_), do: nil

  @doc "Insert a tenant. Idempotent on slug: an existing slug is left unchanged."
  def register(attrs) do
    slug = attrs[:slug] || attrs["slug"]

    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :slug)
    |> case do
      {:ok, _} -> {:ok, get_by_slug(slug)}
      {:error, _} = err -> err
    end
  end
end
