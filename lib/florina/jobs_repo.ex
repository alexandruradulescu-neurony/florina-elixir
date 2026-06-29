defmodule Florina.JobsRepo do
  @moduledoc """
  A second connection pool to the SAME database as `Florina.Repo`, used by Oban
  and by background-job tenant queries (via `Florina.TenantRepo`, which pins it
  per-process in workers). This isolates background-job DB load from the web tier
  so a burst of jobs can't starve live requests' connections.

  Same database → NOT in `:ecto_repos` (migrations run only via `Florina.Repo`);
  this repo just opens its own pool. Only started/used in environments that
  configure it (prod, via `config/runtime.exs`); in dev/test it is unconfigured
  and everything falls back to `Florina.Repo`.
  """
  use Ecto.Repo, otp_app: :florina, adapter: Ecto.Adapters.Postgres
end
