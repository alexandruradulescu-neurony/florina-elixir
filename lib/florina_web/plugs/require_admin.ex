defmodule FlorinaWeb.Plugs.RequireAdmin do
  @moduledoc """
  Plug that enforces operator admin authentication for controller/LiveView routes.

  Reads `admin_id` from the session, loads the admin from the database,
  and assigns it as `:current_admin`. If the session has no valid admin,
  the request is redirected to `/admin/login` and halted.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Florina.Admins

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :admin_id) do
      nil ->
        conn
        |> redirect(to: "/admin/login")
        |> halt()

      id ->
        case Admins.get_admin(id) do
          nil ->
            conn
            |> configure_session(drop: true)
            |> redirect(to: "/admin/login")
            |> halt()

          admin ->
            assign(conn, :current_admin, admin)
        end
    end
  end
end
