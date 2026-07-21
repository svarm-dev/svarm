defmodule SvarmWeb.PageController do
  use SvarmWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
