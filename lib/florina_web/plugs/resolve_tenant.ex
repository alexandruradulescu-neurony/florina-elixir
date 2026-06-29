defmodule FlorinaWeb.Plugs.ResolveTenant do
  @moduledoc """
  Resolves the tenant from the URL path parameter `tenant_slug`
  (e.g. `/t/:tenant_slug/...`), falling back to subdomain extraction when no
  path param is present. Pins the tenant's schema prefix
  (`Process.put(:tenant_prefix, "tenant_<id>")`) so all `Florina.TenantRepo`
  calls in this request hit that tenant's schema, and assigns the tenant on the
  conn. Fails closed (404, halted) when the tenant cannot be resolved.

  Defense in depth: the prefix is cleared in a `before_send` callback, so a
  keep-alive connection process that gets reused for a later request can never
  carry a stale prefix — the next request must re-resolve its own tenant or any
  `TenantRepo` call fails closed. (LiveView and Oban run in per-connection /
  per-job processes that die after use, so they don't need this.)

  Primary resolution: `conn.path_params["tenant_slug"]` — works on any domain,
  including the default Railway domain with no custom domain configured.

  Fallback resolution: subdomain (e.g. `acme.localhost`) — kept so existing
  subdomain-based setups and the `Subdomain` module remain valid, and a future
  custom-domain configuration can still rely on this path.
  """
  import Plug.Conn
  alias Florina.Tenants
  alias Florina.Tenants.Subdomain

  def init(opts), do: opts

  def call(conn, _opts) do
    base = Application.get_env(:florina, :tenant_base_host, "localhost")

    with slug when is_binary(slug) <-
           conn.path_params["tenant_slug"] || Subdomain.extract(conn.host, base),
         %Tenants.Tenant{active: true, status: "active"} = tenant <- Tenants.get_by_slug(slug) do
      Process.put(:tenant_prefix, Tenants.schema_prefix(tenant))
      Logger.metadata(tenant: tenant.slug)

      conn
      |> register_before_send(fn conn ->
        Process.delete(:tenant_prefix)
        conn
      end)
      |> assign(:tenant, tenant)
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Unknown tenant")
        |> halt()
    end
  end
end
