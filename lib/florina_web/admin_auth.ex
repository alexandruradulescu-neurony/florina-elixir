defmodule FlorinaWeb.Admin.AdminAuth do
  @moduledoc """
  LiveView `on_mount` hook that enforces operator admin authentication
  on the websocket layer.

  Usage in a LiveView:

      on_mount FlorinaWeb.Admin.AdminAuth

  If the session contains a valid `admin_id`, the admin is assigned to
  the socket as `:current_admin` and the mount continues. Otherwise the
  socket is halted and redirected to `/admin/login`.
  """
  import Phoenix.Component, only: [assign: 3]
  alias Florina.Admins

  # Called when the LiveView uses `on_mount FlorinaWeb.Admin.AdminAuth` (no atom)
  def on_mount(:default, params, session, socket),
    do: on_mount(:ensure_admin, params, session, socket)

  def on_mount(:ensure_admin, _params, session, socket) do
    case session["admin_id"] do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/admin/login")}

      id ->
        case Admins.get_admin(id) do
          nil ->
            {:halt, Phoenix.LiveView.redirect(socket, to: "/admin/login")}

          admin ->
            {:cont, assign(socket, :current_admin, admin)}
        end
    end
  end
end
