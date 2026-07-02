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
         %Tenants.Tenant{} = tenant <- Tenants.get_accessible(slug) do
      Process.put(:tenant_prefix, Tenants.schema_prefix(tenant))
      Logger.metadata(tenant: tenant.slug)

      {:cont,
       socket
       |> assign(:tenant, tenant)
       |> watch_for_deactivation(tenant.slug)}
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  # The active/status gate is only checked at mount. A long-lived LiveView socket
  # would otherwise keep serving a tenant that was deactivated/suspended after the
  # page connected. Subscribe the connected socket to the tenant's PubSub topic and
  # disconnect it the moment a disable event arrives (Tenants.set_active(false) /
  # set_status to a non-active state broadcasts it). Dead-render (disconnected)
  # mounts skip this — they re-check the gate on their next connected mount anyway.
  defp watch_for_deactivation(socket, slug) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Florina.PubSub, Tenants.pubsub_topic(slug))

      Phoenix.LiveView.attach_hook(socket, :tenant_deactivation_gate, :handle_info, fn
        {:tenant_disabled, ^slug}, sock ->
          {:halt,
           sock
           |> Phoenix.LiveView.put_flash(:error, "This workspace is no longer available.")
           |> Phoenix.LiveView.redirect(to: "/")}

        _msg, sock ->
          {:cont, sock}
      end)
    else
      socket
    end
  end
end
