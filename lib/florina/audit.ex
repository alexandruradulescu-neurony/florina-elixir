defmodule Florina.Audit do
  @moduledoc """
  Context for the immutable activity/audit log (`voice_activitylog`). Per-tenant.
  """
  import Ecto.Query
  alias Florina.TenantRepo
  alias Florina.Audit.ActivityLog
  alias Florina.Strings

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

  @doc """
  Filtered audit list for the Logs screen, newest first, with `:user` and
  `:visit` preloaded. `filters` is a plain map (string keys, as from a form):

    * `"level"`   — one of `Enums.log_level_values/0` strings
    * `"user_id"` — restrict to entries by this user
  """
  def list_filtered(filters \\ %{}, limit \\ 200) do
    from(l in ActivityLog,
      order_by: [desc: l.timestamp],
      preload: [:user, :visit],
      limit: ^limit
    )
    |> filter_level(Strings.blank_to_nil(filters["level"]))
    |> filter_user(Strings.to_int(filters["user_id"]))
    |> TenantRepo.all()
  end

  defp filter_level(query, nil), do: query

  defp filter_level(query, level) do
    # `level` is a URL/form param; an unknown value would crash `to_existing_atom`,
    # so an unrecognised filter just drops to "no filter".
    case safe_existing_atom(level) do
      nil -> query
      atom -> from(l in query, where: l.level == ^atom)
    end
  end

  defp safe_existing_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp filter_user(query, nil), do: query
  defp filter_user(query, user_id), do: from(l in query, where: l.user_id == ^user_id)

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
