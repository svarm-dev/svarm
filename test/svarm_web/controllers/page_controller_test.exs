defmodule SvarmWeb.PageControllerTest do
  use SvarmWeb.ConnCase

  test "GET / shows marketing and this-instance status", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "Governed agents on your tickets"
    assert body =~ "Open board"
    assert body =~ "This instance"
    assert body =~ "Tracker"
    assert body =~ "Agents"
    refute body =~ "Peace of mind from prototype to production"
  end

  test "GET /health returns ok", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert response(conn, 200) == "ok"
  end
end
