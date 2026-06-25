defmodule Florina.Methodologies do
  @moduledoc """
  Context for sales methodologies (SPIN, MEDDIC, Challenger, …).

  Mirrors Django's `get_active_methodologies / get_methodology_by_id` selectors
  and the methodology CRUD views.

  All queries hit `TenantRepo`.
  """

  import Ecto.Query, only: [order_by: 2, where: 2]
  alias Florina.TenantRepo
  alias Florina.Methodologies.Methodology

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc "Returns all methodologies ordered by name."
  def list do
    Methodology
    |> order_by(:name)
    |> TenantRepo.all()
  end

  @doc """
  Returns only active methodologies, ordered by name.

  Mirrors Django's `get_active_methodologies()`.
  """
  def list_active do
    Methodology
    |> where(is_active: true)
    |> order_by(:name)
    |> TenantRepo.all()
  end

  @doc "Gets a methodology by ID. Raises `Ecto.NoResultsError` if not found."
  def get!(id) do
    TenantRepo.get!(Methodology, id)
  end

  @doc "Gets a methodology by ID. Returns `nil` if not found."
  def get(id) do
    TenantRepo.get(Methodology, id)
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a methodology.

  Automatically sets `is_overridden: true` so publish won't overwrite this
  tenant-local row. A fuller id-space partition (to avoid id collisions with
  canonical rows) is deferred as future work.

  Returns `{:ok, methodology}` or `{:error, changeset}`.
  """
  def create(attrs \\ %{}) do
    %Methodology{}
    |> Methodology.changeset(attrs)
    |> Ecto.Changeset.put_change(:is_overridden, true)
    |> TenantRepo.insert()
  end

  @doc """
  Updates a methodology.

  Automatically sets `is_overridden: true` so publish won't overwrite this
  tenant-local edit.

  Returns `{:ok, methodology}` or `{:error, changeset}`.
  """
  def update(%Methodology{} = methodology, attrs) do
    methodology
    |> Methodology.changeset(attrs)
    |> Ecto.Changeset.put_change(:is_overridden, true)
    |> TenantRepo.update()
  end

  @doc """
  Deletes a methodology.

  Returns `{:ok, methodology}` or `{:error, changeset}`.
  """
  def delete(%Methodology{} = methodology) do
    TenantRepo.delete(methodology)
  end
end
