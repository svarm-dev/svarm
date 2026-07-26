defmodule SvarmWeb.ApprovalsControllerTest do
  use SvarmWeb.ConnCase

  alias Svarm.{Approval, KanbanBridge}

  setup do
    # Ensure active tracker is Local (Settings overlay can leak from other tests).
    Svarm.Settings.Store.delete("tracker")

    task =
      KanbanBridge.create_task(%{
        title: "Gate me",
        status: Approval.pending_status(),
        assignee: "cody"
      })

    {:ok, task: task}
  end

  test "GET /approvals lists pending tasks", %{conn: conn, task: task} do
    conn = get(conn, ~p"/approvals")
    body = html_response(conn, 200)
    assert body =~ "Approvals"
    assert body =~ task.id
    assert body =~ "approval-approve-#{task.id}"
  end

  test "POST approve moves task to todo", %{conn: conn, task: task} do
    conn =
      post(conn, ~p"/approvals/#{task.id}/approve", %{
        "_csrf_token" => Plug.CSRFProtection.get_csrf_token()
      })

    assert redirected_to(conn) == ~p"/approvals"
    assert %{status: "todo"} = KanbanBridge.get_task(task.id)
  end

  test "POST reject moves task to failed", %{conn: conn, task: task} do
    conn =
      post(conn, ~p"/approvals/#{task.id}/reject", %{
        "_csrf_token" => Plug.CSRFProtection.get_csrf_token()
      })

    assert redirected_to(conn) == ~p"/approvals"
    assert %{status: "failed"} = KanbanBridge.get_task(task.id)
  end
end
