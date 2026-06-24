defmodule Florina.Repo do
  use Ecto.Repo,
    otp_app: :florina,
    adapter: Ecto.Adapters.Postgres
end
