defmodule Florina.TenantRepo do
  @moduledoc """
  Dynamic, per-tenant repository. It has NO fixed database. The connection
  manager starts a named instance per tenant; each request pins the right one
  with `put_dynamic_repo/1`. Deliberately absent from `:ecto_repos`, so the
  normal `mix ecto.migrate` and the release migrator never touch it.
  """
  use Ecto.Repo, otp_app: :florina, adapter: Ecto.Adapters.Postgres
end
