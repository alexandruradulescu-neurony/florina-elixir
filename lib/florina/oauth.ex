defmodule Florina.OAuth do
  @moduledoc "Per-tenant OAuth credential store (agent calendar + future Florina mailbox)."
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.OAuth.Credential

  def get_calendar_credential_for_user(user_id) do
    TenantRepo.get_by(Credential, user_id: user_id, purpose: :agent_calendar)
  end

  def list_calendar_credentials do
    from(c in Credential, where: c.purpose == :agent_calendar) |> TenantRepo.all()
  end

  @doc "Insert or update an agent's calendar credential for a provider (idempotent per user+provider)."
  def upsert_calendar_credential(user_id, provider, attrs) when is_atom(provider) do
    attrs = Map.merge(attrs, %{user_id: user_id, provider: provider, purpose: :agent_calendar})

    case TenantRepo.get_by(Credential,
           user_id: user_id,
           provider: provider,
           purpose: :agent_calendar
         ) do
      nil -> %Credential{} |> Credential.changeset(attrs) |> TenantRepo.insert()
      existing -> existing |> Credential.changeset(attrs) |> TenantRepo.update()
    end
  end

  def update_credential(%Credential{} = c, attrs),
    do: c |> Credential.changeset(attrs) |> TenantRepo.update()

  def delete_credential(%Credential{} = c), do: TenantRepo.delete(c)
end
