defmodule Florina.Scenarios do
  @moduledoc """
  Context for visit scenario types (discovery, follow-up, closing, debrief, …).

  All queries hit `TenantRepo`.
  """

  import Ecto.Query, only: [order_by: 2, where: 2]
  alias Florina.TenantRepo
  alias Florina.Scenarios.Scenario

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc "Returns all scenarios ordered by name."
  def list do
    Scenario
    |> order_by(:name)
    |> TenantRepo.all()
  end

  @doc "Returns only active scenarios ordered by name."
  def list_active do
    Scenario
    |> where(is_active: true)
    |> order_by(:name)
    |> TenantRepo.all()
  end

  @doc "Gets a scenario by ID. Raises `Ecto.NoResultsError` if not found."
  def get!(id) do
    TenantRepo.get!(Scenario, id)
  end

  @doc "Gets a scenario by ID. Returns `nil` if not found."
  def get(id) do
    TenantRepo.get(Scenario, id)
  end

  @doc "Gets a scenario by its URL slug. Returns `nil` if not found."
  def get_by_slug(slug) when is_binary(slug) do
    TenantRepo.get_by(Scenario, slug: slug)
  end

  def get_by_slug(_), do: nil

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a scenario.

  Returns `{:ok, scenario}` or `{:error, changeset}`.
  """
  def create(attrs \\ %{}) do
    %Scenario{}
    |> Scenario.changeset(attrs)
    |> TenantRepo.insert()
  end

  @doc """
  Updates a scenario.

  Returns `{:ok, scenario}` or `{:error, changeset}`.
  """
  def update(%Scenario{} = scenario, attrs) do
    scenario
    |> Scenario.changeset(attrs)
    |> TenantRepo.update()
  end

  @doc """
  Deletes a scenario.

  Returns `{:ok, scenario}` or `{:error, changeset}`.
  """
  def delete(%Scenario{} = scenario) do
    TenantRepo.delete(scenario)
  end
end
