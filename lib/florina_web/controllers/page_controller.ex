defmodule FlorinaWeb.PageController do
  use FlorinaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
