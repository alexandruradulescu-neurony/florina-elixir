defmodule FlorinaWeb.Admin.SessionController do
  @moduledoc "Email + password login / logout for the operator admin area."
  use FlorinaWeb, :controller

  alias Florina.Admins

  # GET /admin/login
  def new(conn, _params) do
    render(conn, :new, error: nil)
  end

  # POST /admin/login
  def create(conn, %{"admin" => %{"email" => email, "password" => password}}) do
    case Admins.authenticate(email, password) do
      {:ok, admin} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:admin_id, admin.id)
        |> redirect(to: ~p"/admin/tenants")

      {:error, :invalid} ->
        conn
        |> put_flash(:error, "Invalid email or password.")
        |> render(:new, error: "Invalid email or password.")
    end
  end

  # DELETE /admin/logout
  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/admin/login")
  end
end
