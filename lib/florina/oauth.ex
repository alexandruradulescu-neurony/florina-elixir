defmodule Florina.OAuth do
  @moduledoc "Per-tenant OAuth credential store (agent calendar + future Florina mailbox)."
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.OAuth.Credential

  @doc """
  A single calendar credential for the user (lowest id). Safe when an agent has
  connected more than one provider — `get_by` would raise `MultipleResultsError`.
  Prefer `list_calendar_credentials_for_user/1` when you must cover every provider.
  """
  def get_calendar_credential_for_user(user_id) do
    from(c in Credential,
      where: c.user_id == ^user_id and c.purpose == :agent_calendar,
      order_by: [asc: c.id],
      limit: 1
    )
    |> TenantRepo.one()
  end

  @doc "All of an agent's calendar credentials — at most one row per provider."
  def list_calendar_credentials_for_user(user_id) do
    from(c in Credential, where: c.user_id == ^user_id and c.purpose == :agent_calendar)
    |> TenantRepo.all()
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
      nil ->
        %Credential{} |> Credential.changeset(attrs) |> TenantRepo.insert()

      existing ->
        existing
        |> Credential.changeset(preserve_refresh_token(attrs, existing))
        |> TenantRepo.update()
    end
  end

  # Providers commonly omit the refresh token on re-consent (Google without
  # prompt=consent, Microsoft re-login). Don't let a missing/blank value blow away
  # the refresh token we already stored — sync would break once the access token
  # expires. Drop the key from the update attrs so the existing value is kept.
  defp preserve_refresh_token(attrs, %Credential{refresh_token: existing})
       when is_binary(existing) and existing != "" do
    if Map.get(attrs, :refresh_token, Map.get(attrs, "refresh_token")) in [nil, ""] do
      attrs |> Map.delete(:refresh_token) |> Map.delete("refresh_token")
    else
      attrs
    end
  end

  defp preserve_refresh_token(attrs, _existing), do: attrs

  def update_credential(%Credential{} = c, attrs),
    do: c |> Credential.changeset(attrs) |> TenantRepo.update()

  def delete_credential(%Credential{} = c), do: TenantRepo.delete(c)
end
