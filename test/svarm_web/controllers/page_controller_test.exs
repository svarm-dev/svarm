defmodule SvarmWeb.PageControllerTest do
  use SvarmWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "Your AI teammates, governed"
    assert body =~ "Open team board"
    refute body =~ "Peace of mind from prototype to production"
  end
end
