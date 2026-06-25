defmodule FlorinaWeb.PageController do
  use FlorinaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  # Dev-only preview of the agent app shell (wired under the router's dev_routes
  # block). Lets us eyeball the layout without an agent session; not compiled in prod.
  def shell_preview(conn, _params) do
    conn
    |> assign(:tenant, %{slug: "leadder", name: "Leadder"})
    |> assign(:current_agent, %{
      first_name: "Alex",
      last_name: "Radulescu",
      email: "alex@leadder.com"
    })
    |> render(:shell_preview)
  end
end
