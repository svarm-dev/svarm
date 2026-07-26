defmodule SvarmWeb.PageControllerTest do
  use SvarmWeb.ConnCase

  test "GET / shows marketing and this-instance status", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "Control for your agent loop"
    assert body =~ "Open board"
    assert body =~ "agents do not merge"
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
