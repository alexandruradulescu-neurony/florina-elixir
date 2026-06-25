defmodule FlorinaWeb.TenantHook do
  @moduledoc "Resolves + pins the tenant for a LiveView from the session slug. Fails closed."
  import Phoenix.Component, only: [assign: 3]
  alias Florina.Tenants
  alias Florina.Tenants.ConnectionManager

  def on_mount(:default, _params, session, socket) do
    with slug when is_binary(slug) <- session["tenant_slug"],
         %Tenants.Tenant{active: true, status: "active"} = tenant <- Tenants.get_by_slug(slug),
         {:ok, pid} <- ConnectionManager.ensure_started(slug) do
      Florina.TenantRepo.put_dynamic_repo(pid)
      {:cont, assign(socket, :tenant, tenant)}
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end
end
