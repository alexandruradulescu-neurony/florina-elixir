defmodule Florina.Tenants.ConnectionOpts do
  @moduledoc """
  Builds the connection options for a per-tenant `Florina.TenantRepo` instance
  from the control-plane repo's base configuration, overriding only the database.

  Handles both shapes of base config:

    * local/dev/test — discrete `:username`, `:hostname`, ... fields; we reuse
      them and swap the `:database`.
    * production — a single `:url` (set from `DATABASE_URL` on Railway); we swap
      only the database segment of that URL.
  """

  @doc "Connection options for a tenant database, given the base `Florina.Repo` config."
  def build(base, database, pool_size) do
    extras = Keyword.take(base, [:socket_options, :ssl])

    conn =
      case Keyword.get(base, :url) do
        nil ->
          base
          |> Keyword.take([:username, :password, :hostname, :port])
          |> Keyword.put(:database, database)

        url ->
          [url: swap_database(url, database)]
      end

    extras ++ conn ++ [name: nil, pool_size: pool_size]
  end

  # Replace only the database (the URL path), preserving credentials, host,
  # port and any query parameters.
  defp swap_database(url, database) do
    url
    |> URI.parse()
    |> Map.put(:path, "/" <> database)
    |> URI.to_string()
  end
end
