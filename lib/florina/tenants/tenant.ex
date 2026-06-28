defmodule Florina.Tenants.Tenant do
  @moduledoc """
  A tenant in the control-plane registry: slug, name, status, and allowed SSO
  domains. Tenant data is isolated by Postgres schema (`tenant_<id>`), derived
  from the immutable id — there is no per-tenant database.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(provisioning active failed)

  schema "tenants" do
    field :slug, :string
    field :name, :string
    field :active, :boolean, default: true
    field :status, :string, default: "active"
    field :allowed_email_domains, {:array, :string}, default: []
    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name, :active, :status, :allowed_email_domains])
    |> validate_required([:slug, :name])
    |> validate_inclusion(:status, @valid_statuses)
    |> normalize_domains()
    |> unique_constraint(:slug)
  end

  defp normalize_domains(changeset) do
    case Ecto.Changeset.get_change(changeset, :allowed_email_domains) do
      nil ->
        changeset

      domains ->
        cleaned =
          domains
          |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
          |> Enum.reject(&(&1 == ""))

        Ecto.Changeset.put_change(changeset, :allowed_email_domains, cleaned)
    end
  end
end
