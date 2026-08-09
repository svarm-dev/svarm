defmodule SvarmWeb.DashboardLiveTest do
  use SvarmWeb.LiveCase, async: false

  alias Svarm.{Approval, KanbanBridge, Repo, Usage}

  setup do
    KanbanBridge.delete_all_tasks()
    Repo.delete_all("usage_records")
    :ok
  end

  test "shows waiting on humans strip with counts", %{conn: conn} do
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
    assert html =~ ~p"/board"
    assert html =~ "Spend"
    assert html =~ "Who&#39;s working" or html =~ "Who's working"
  end

  test "zero wait strip still renders", %{conn: conn} do
    KanbanBridge.create_task(%{title: "Todo only", status: "todo", assignee: "demo"})

    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Waiting on humans"
    assert html =~ "Approvals 0"
    assert html =~ "Review 0"
    assert html =~ "Total 0"
    assert html =~ "nothing waiting on humans"
  end

  test "session spend shows cost and tokens from same window", %{conn: conn} do
    task =
      KanbanBridge.create_task(%{
        title: "Done with spend",
        status: "done",
        assignee: nil
      })

    Usage.append(%{
      run_id: "run_dash_1",
      task_id: task.id,
      source: "worker",
      provider: "openrouter",
      model_id: "claude-sonnet-4-20250514",
      prompt_tokens: 1_000,
      completion_tokens: 500,
      estimated: false
    })

    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Spend"
    # 1000 + 500 tokens, formatted as 1.5K — must not stay 0 when cost exists
    assert html =~ "1.5K"
    assert html =~ "active · 1 done"
    assert html =~ "Done with spend"
    assert html =~ "task=#{task.id}"

    html = render_click(view, "set_window", %{"window" => "24h"})
    assert html =~ "Spend"
    assert html =~ "1.5K"
  end

  test "orchestrator_status bursts coalesce into one dashboard reload", %{conn: conn} do
    KanbanBridge.create_task(%{
      title: "Dash coalesce",
      status: "todo",
      assignee: "demo"
    })

    {:ok, view, html} = live(conn, ~p"/dashboard")
    assert html =~ "Waiting on humans"

    # Storm of high-frequency status ticks — schedules at most one coalesced reload.
    for i <- 1..5 do
      send(view.pid, {:orchestrator_status, %{running: i, claimed: 0, retrying: 0, completed: 0}})
    end

    :sys.get_state(view.pid)

    # After coalesce window, LiveView is still healthy (no crash / disconnect).
    Process.sleep(900)
    :sys.get_state(view.pid)
    html = render(view)
    assert html =~ "Waiting on humans"
    assert html =~ "Dashboard"
  end
end
