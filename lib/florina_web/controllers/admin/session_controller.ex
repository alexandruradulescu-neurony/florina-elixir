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
    rate_key = rate_key(email)

    case LoginRateLimiter.check_and_count(rate_key) do
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
            # The attempt was already counted by check_and_count/1.
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

  # Rate-limit per submitted email (normalized), NOT per IP: behind Railway's
  # proxy every request shares one upstream IP, so an IP key would let a few bad
  # logins lock out all admins at once. Per-email keying bounds guesses against
  # each account without that global-lockout blast radius.
  defp rate_key(email), do: email |> to_string() |> String.trim() |> String.downcase()
end
