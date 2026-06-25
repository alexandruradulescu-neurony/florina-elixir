defmodule Florina.Audit do
  @moduledoc """
  Context for the immutable activity/audit log (`voice_activitylog`). Per-tenant.
  """
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.Audit.ActivityLog

  @doc """
  Record an audit entry. `attrs` needs at least `:action`; `:visit_id`, `:user_id`,
  `:details`, `:level` are optional. Sets `:timestamp` if absent.
  """
  def log(attrs) do
    attrs = Map.put_new(attrs, :timestamp, now())
    %ActivityLog{} |> ActivityLog.changeset(attrs) |> TenantRepo.insert()
  end

  def list_recent(limit \\ 100),
    do: TenantRepo.all(from l in ActivityLog, order_by: [desc: l.timestamp], limit: ^limit)

  def list_for_visit(visit_id),
    do:
      TenantRepo.all(
        from l in ActivityLog, where: l.visit_id == ^visit_id, order_by: [desc: l.timestamp]
      )

  def list_for_user(user_id),
    do:
      TenantRepo.all(
        from l in ActivityLog, where: l.user_id == ^user_id, order_by: [desc: l.timestamp]
      )

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
