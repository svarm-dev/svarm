defmodule SvarmWeb.DashboardLiveTest do
  use SvarmWeb.LiveCase, async: false

  alias Svarm.{Approval, KanbanBridge}

  test "shows waiting on humans strip with counts", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    KanbanBridge.create_task(%{
      title: "Need gate",
      status: Approval.pending_status(),
      assignee: "demo"
    })

    KanbanBridge.create_task(%{
      title: "Need review",
      status: "review",
      assignee: "demo"
    })

    KanbanBridge.create_task(%{
      title: "Just todo",
      status: "todo",
      assignee: "demo"
    })

    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Waiting on humans"
    assert html =~ "Approvals 1"
    assert html =~ "Review 1"
    assert html =~ "Total 2"
    assert html =~ ~p"/approvals"
    assert html =~ ~p"/board"
  end

  test "zero wait strip still renders", %{conn: conn} do
    KanbanBridge.delete_all_tasks()
    KanbanBridge.create_task(%{title: "Todo only", status: "todo", assignee: "demo"})

    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Waiting on humans"
    assert html =~ "Approvals 0"
    assert html =~ "Review 0"
    assert html =~ "Total 0"
  end
end
