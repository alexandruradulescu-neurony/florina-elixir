defmodule FlorinaWeb.Plugs.ResolveTenant do
  @moduledoc """
  Resolves the tenant from the request subdomain, pins `Florina.TenantRepo` to
  that tenant's database, and assigns the tenant on the conn. Fails closed
  (404, halted) when the tenant cannot be resolved.
  """
  import Plug.Conn
  alias Florina.Tenants
  alias Florina.Tenants.{ConnectionManager, Subdomain}

  def init(opts), do: opts

  def call(conn, _opts) do
    base = Application.get_env(:florina, :tenant_base_host, "localhost")

    with slug when is_binary(slug) <- Subdomain.extract(conn.host, base),
         %Tenants.Tenant{active: true} = tenant <- Tenants.get_by_slug(slug),
         {:ok, pid} <- ConnectionManager.ensure_started(tenant.slug) do
      Florina.TenantRepo.put_dynamic_repo(pid)
      conn = assign(conn, :tenant, tenant)
      if Map.has_key?(conn.private, :plug_session), do: put_session(conn, :tenant_slug, tenant.slug), else: conn
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Unknown tenant")
        |> halt()
    end
  end
end
