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

  @doc """
  Discrete server connection params (host/user/password/port + socket_options/ssl),
  WITHOUT a database, derived from the base `Florina.Repo` config — handling a
  production `:url` (DATABASE_URL) by parsing it. Suitable for `storage_up`/
  `storage_down`, which (unlike `Repo.start_link`) do NOT parse a `:url`.
  """
  def server_params(base \\ base_config()) do
    extras = Keyword.take(base, [:socket_options, :ssl])

    conn =
      case Keyword.get(base, :url) do
        nil -> Keyword.take(base, [:username, :password, :hostname, :port])
        url -> parse_url(url)
      end

    extras ++ conn
  end

  @doc """
  The database name the app itself connects to (url-aware). Usable as the
  maintenance database when issuing `CREATE DATABASE` for a new tenant.
  """
  def app_database(base \\ base_config()) do
    case Keyword.get(base, :url) do
      nil -> Keyword.get(base, :database)
      url -> URI.parse(url).path |> to_string() |> String.trim_leading("/")
    end
  end

  defp base_config, do: Application.get_env(:florina, Florina.Repo)

  defp parse_url(url) do
    uri = URI.parse(url)

    {user, pass} =
      case uri.userinfo do
        nil -> {nil, nil}
        ui -> case String.split(ui, ":", parts: 2) do
                [u, p] -> {u, p}
                [u] -> {u, nil}
              end
      end

    [username: user, password: pass, hostname: uri.host, port: uri.port]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
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
