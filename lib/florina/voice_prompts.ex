defmodule Florina.VoicePrompts do
  @moduledoc """
  Context for the AI voice agent's editable system prompts (`voice_voiceprompt`).

  At most one active prompt per type (PRE/POST). `activate/1` flips the active
  one atomically. Per-tenant (`TenantRepo`).
  """
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.Calls.VoicePrompt

  def list, do: TenantRepo.all(from p in VoicePrompt, order_by: [desc: p.created_at])

  def list_by_type(type),
    do:
      TenantRepo.all(
        from p in VoicePrompt, where: p.prompt_type == ^type, order_by: [desc: p.created_at]
      )

  def get!(id), do: TenantRepo.get!(VoicePrompt, id)
  def get(id), do: TenantRepo.get(VoicePrompt, id)

  @doc "The single active prompt for a type (:PRE/:POST), or nil."
  def get_active(type),
    do:
      TenantRepo.one(
        from p in VoicePrompt, where: p.prompt_type == ^type and p.is_active == true, limit: 1
      )

  @doc """
  Creates a voice prompt.

  Automatically sets `is_overridden: true` so publish won't overwrite this
  tenant-local row. A fuller id-space partition (to avoid id collisions with
  canonical rows) is deferred as future work.
  """
  def create(attrs) do
    attrs = Map.put(attrs, :is_overridden, true)
    %VoicePrompt{} |> VoicePrompt.changeset(attrs) |> TenantRepo.insert()
  end

  @doc """
  Updates a voice prompt.

  Automatically sets `is_overridden: true` so publish won't overwrite this
  tenant-local edit.
  """
  def update(%VoicePrompt{} = p, attrs) do
    attrs = Map.put(attrs, :is_overridden, true)
    p |> VoicePrompt.changeset(attrs) |> TenantRepo.update()
  end

  def delete(%VoicePrompt{} = p), do: TenantRepo.delete(p)

  @doc "Make this prompt the single active one for its type (deactivates siblings)."
  def activate(%VoicePrompt{} = prompt) do
    TenantRepo.transaction(fn ->
      from(p in VoicePrompt,
        where: p.prompt_type == ^prompt.prompt_type and p.id != ^prompt.id and p.is_active == true
      )
      |> TenantRepo.update_all(set: [is_active: false])

      {:ok, updated} = prompt |> VoicePrompt.changeset(%{is_active: true}) |> TenantRepo.update()
      updated
    end)
  end
end
