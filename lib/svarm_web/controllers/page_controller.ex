defmodule SvarmWeb.PageController do
  use SvarmWeb, :controller

  alias Svarm.Board

  def home(conn, _params) do
    render(conn, :home, instance: Board.instance_status())
  end

  def health(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
