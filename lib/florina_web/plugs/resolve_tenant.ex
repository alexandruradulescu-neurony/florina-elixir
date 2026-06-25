defmodule FlorinaWeb.Plugs.ResolveTenant do
  @moduledoc """
  Resolves the tenant from the URL path parameter `tenant_slug`
  (e.g. `/t/:tenant_slug/...`), falling back to subdomain extraction when no
  path param is present. Pins `Florina.TenantRepo` to that tenant's database
  and assigns the tenant on the conn. Fails closed (404, halted) when the
  tenant cannot be resolved.

  Primary resolution: `conn.path_params["tenant_slug"]` — works on any domain,
  including the default Railway domain with no custom domain configured.

  Fallback resolution: subdomain (e.g. `acme.localhost`) — kept so existing
  subdomain-based setups and the `Subdomain` module remain valid, and a future
  custom-domain configuration can still rely on this path.
  """
  import Plug.Conn
  alias Florina.Tenants
  alias Florina.Tenants.{ConnectionManager, Subdomain}

  def init(opts), do: opts

  def call(conn, _opts) do
    base = Application.get_env(:florina, :tenant_base_host, "localhost")

    with slug when is_binary(slug) <-
           conn.path_params["tenant_slug"] || Subdomain.extract(conn.host, base),
         %Tenants.Tenant{active: true} = tenant <- Tenants.get_by_slug(slug),
         {:ok, pid} <- ConnectionManager.ensure_started(slug) do
      Florina.TenantRepo.put_dynamic_repo(pid)
      assign(conn, :tenant, tenant)
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Unknown tenant")
        |> halt()
    end
  end
end
