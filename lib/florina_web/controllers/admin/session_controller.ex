defmodule FlorinaWeb.Admin.SessionController do
  @moduledoc "Email + password login / logout for the operator admin area."
  use FlorinaWeb, :controller

  alias Florina.Admins
  alias Florina.Auth.LoginRateLimiter

  # GET /admin/login
  def new(conn, _params) do
    render(conn, :new, error: nil)
  end

  # POST /admin/login
  def create(conn, %{"admin" => %{"email" => email, "password" => password}}) do
    rate_key = rate_key(conn)

    case LoginRateLimiter.check(rate_key) do
      {:error, :rate_limited} ->
        msg = "Too many failed attempts. Please wait a few minutes and try again."

        conn
        |> put_flash(:error, msg)
        |> render(:new, error: msg)

      :ok ->
        case Admins.authenticate(email, password) do
          {:ok, admin} ->
            LoginRateLimiter.clear(rate_key)

            conn
            |> configure_session(renew: true)
            |> put_session(:admin_id, admin.id)
            |> redirect(to: ~p"/admin/tenants")

          {:error, :invalid} ->
            LoginRateLimiter.record_failure(rate_key)

            conn
            |> put_flash(:error, "Invalid email or password.")
            |> render(:new, error: "Invalid email or password.")
        end
    end
  end

  # DELETE /admin/logout
  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/admin/login")
  end

  # Rate-limit per client IP. Behind Railway's proxy the real IP arrives via
  # x-forwarded-for; RemoteIp/PlugAttack aren't wired up, so fall back to
  # remote_ip (the proxy) — still bounds total attempts, just less granular.
  defp rate_key(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
