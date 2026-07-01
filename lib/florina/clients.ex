defmodule Florina.Clients do
  @moduledoc """
  Context for client/company records synced from CRM.

  Mirrors Django's `get_all_clients`, `get_client_by_domain`,
  `get_client_by_crm_id`, and the client CRUD views.

  All queries hit `TenantRepo`.
  """

  import Ecto.Query, only: [order_by: 2, where: 2]
  alias Florina.TenantRepo
  alias Florina.Clients.{Client, Document}
  alias Florina.Storage

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns all clients ordered by name.

  Mirrors Django's `get_all_clients()` selector (without the Django default
  limit of 100 — callers that need pagination should add their own limit).
  """
  def list do
    Client
    |> order_by(:name)
    |> TenantRepo.all()
  end

  @doc "Gets a client by ID. Raises `Ecto.NoResultsError` if not found."
  def get!(id) do
    TenantRepo.get!(Client, id)
  end

  @doc "Gets a client by ID. Returns `nil` if not found."
  def get(id) when is_integer(id), do: TenantRepo.get(Client, id)

  # Tolerate a non-integer id (e.g. a hand-edited URL) — return nil instead of
  # raising Ecto.Query.CastError against the bigint primary key.
  def get(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> TenantRepo.get(Client, int)
      _ -> nil
    end
  end

  def get(_), do: nil

  @doc """
  Finds the first client matching the given email domain.

  Mirrors Django's `get_client_by_domain()`. Used by the calendar sync
  pipeline to match attendees to a known client. The domain is normalised
  (`Client.normalize_domain/1`) so case / `www.` variants match the one stored row.
  """
  def get_by_domain(domain) when is_binary(domain) do
    case Client.normalize_domain(domain) do
      nil -> nil
      normalized -> TenantRepo.get_by(Client, domain: normalized)
    end
  end

  def get_by_domain(_), do: nil

  @doc """
  Finds a client by its CRM identifier (e.g. Pipedrive org ID).

  Mirrors Django's `get_client_by_crm_id()`. Returns `nil` if not found.
  """
  def get_by_crm_id(crm_id) when is_binary(crm_id) do
    TenantRepo.get_by(Client, crm_id: crm_id)
  end

  def get_by_crm_id(_), do: nil

  @doc """
  Returns clients filtered by status atom (`:new` or `:existing`).

  The Ecto enum stores `"nou"` / `"existent"` — use the atom key (`:new` /
  `:existing`) as defined in `Florina.Enums.client_status_values/0`.
  """
  def list_by_status(status) do
    Client
    |> where(status: ^status)
    |> order_by(:name)
    |> TenantRepo.all()
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a client record.

  Returns `{:ok, client}` or `{:error, changeset}`.
  """
  def create(attrs \\ %{}) do
    %Client{}
    |> Client.changeset(attrs)
    |> TenantRepo.insert()
  end

  @doc """
  Updates a client record.

  Returns `{:ok, client}` or `{:error, changeset}`.
  """
  def update(%Client{} = client, attrs) do
    client
    |> Client.changeset(attrs)
    |> TenantRepo.update()
  end

  @doc """
  Deletes a client record.

  Returns `{:ok, client}` or `{:error, changeset}`.
  """
  def delete(%Client{} = client) do
    # FKs from visits / generation-runs are :restrict, so deleting a client that
    # still has history raises at the DB. Map that to a clean {:error, changeset}.
    client
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :voice_visit_client_id_fkey,
      message: "has related meetings"
    )
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :voice_generationrun_client_id_fkey,
      message: "has related generation runs"
    )
    |> TenantRepo.delete()
  end

  # ---------------------------------------------------------------------------
  # Documents (uploaded files attached to a client)
  # ---------------------------------------------------------------------------

  @doc "Lists a client's uploaded documents, newest first."
  def list_documents(client_id) do
    Document
    |> where(client_id: ^client_id)
    |> order_by(desc: :created_at, desc: :id)
    |> TenantRepo.all()
  end

  @doc "Gets a document by ID. Returns `nil` if not found or the id isn't numeric."
  def get_document(id) when is_integer(id), do: TenantRepo.get(Document, id)

  def get_document(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> TenantRepo.get(Document, int)
      _ -> nil
    end
  end

  def get_document(_), do: nil

  @doc """
  Creates a document metadata row (the bytes are written by `Florina.Storage`
  first). Returns `{:ok, document}` or `{:error, changeset}`.
  """
  def create_document(attrs) do
    %Document{}
    |> Document.changeset(attrs)
    |> TenantRepo.insert()
  end

  @doc "Updates a document row (used by the extraction worker to store text/status)."
  def update_document(%Document{} = document, attrs) do
    document
    |> Document.changeset(attrs)
    |> TenantRepo.update()
  end

  @doc """
  Deletes a document: removes the DB row first, then the file on disk. If the row
  delete fails the bytes are left in place (nothing is orphaned in the listing).
  `tenant_id` locates the file on the uploads volume.
  """
  def delete_document(%Document{} = document, tenant_id) do
    case TenantRepo.delete(document) do
      {:ok, deleted} ->
        Storage.delete_file(tenant_id, document.client_id, document.stored_filename)
        {:ok, deleted}

      other ->
        other
    end
  end
end
