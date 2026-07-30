defmodule SvarmWeb.DevDemoControllerTest do
  use SvarmWeb.ConnCase, async: false

  test "POST /dev/demo/seed redirects to board with tasks", %{conn: conn} do
    conn =
      post(conn, ~p"/dev/demo/seed?goal=test+goal")

    assert redirected_to(conn) == ~p"/board"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "queued"
    assert Enum.any?(Svarm.KanbanBridge.list_tasks([]), &String.contains?(&1.title, "Demo:"))
  end
end
