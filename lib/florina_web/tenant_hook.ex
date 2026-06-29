defmodule FlorinaWeb.TenantHook do
  @moduledoc """
  Resolves + pins the tenant for a LiveView from the session slug. Pins the
  tenant's schema prefix on the LiveView process so `Florina.TenantRepo` calls
  hit that tenant's schema. Fails closed.
  """
  import Phoenix.Component, only: [assign: 3]
  alias Florina.Tenants

  def on_mount(:default, _params, session, socket) do
    with slug when is_binary(slug) <- session["tenant_slug"],
         %Tenants.Tenant{active: true, status: "active"} = tenant <- Tenants.get_by_slug(slug) do
      Process.put(:tenant_prefix, Tenants.schema_prefix(tenant))
      Logger.metadata(tenant: tenant.slug)
      {:cont, assign(socket, :tenant, tenant)}
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end
end
