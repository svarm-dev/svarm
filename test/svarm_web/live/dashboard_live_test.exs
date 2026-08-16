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
    assert html =~ "Wall-clock last 24 hours"
  end

  test "24h chip excludes ledger rows older than a day on the wall clock", %{conn: conn} do
    now = DateTime.utc_now()

    Repo.insert!(%Svarm.Usage.Record{
      id: "use_dash_old",
      run_id: "run_old",
      task_id: "task_old",
      source: "worker",
      provider: "openrouter",
      model_id: "unknown-model",
      prompt_tokens: 0,
      completion_tokens: 0,
      estimated: false,
      provider_cost_usd: 9.0,
      recorded_at: 0,
      inserted_at: DateTime.add(now, -8 * 86_400, :second)
    })

    Repo.insert!(%Svarm.Usage.Record{
      id: "use_dash_mid",
      run_id: "run_mid",
      task_id: "task_mid",
      source: "worker",
      provider: "openrouter",
      model_id: "unknown-model",
      prompt_tokens: 0,
      completion_tokens: 0,
      estimated: false,
      provider_cost_usd: 2.0,
      recorded_at: 0,
      inserted_at: DateTime.add(now, -2 * 86_400, :second)
    })

    Repo.insert!(%Svarm.Usage.Record{
      id: "use_dash_new",
      run_id: "run_new",
      task_id: "task_new",
      source: "worker",
      provider: "openrouter",
      model_id: "unknown-model",
      prompt_tokens: 0,
      completion_tokens: 0,
      estimated: false,
      provider_cost_usd: 1.25,
      recorded_at: 0,
      inserted_at: now
    })

    {:ok, view, html} = live(conn, ~p"/dashboard")
    assert html =~ "$12.25"
    assert html =~ "All ledger rows in this database"

    html = render_click(view, "set_window", %{"window" => "24h"})
    assert html =~ "Wall-clock last 24 hours"
    assert html =~ "$1.25"
    refute html =~ "$12.25"
    refute html =~ "$9.0"

    html = render_click(view, "set_window", %{"window" => "7d"})
    assert html =~ "Wall-clock last 7 days"
    assert html =~ "$3.25"
    refute html =~ "$12.25"

    html = render_click(view, "set_window", %{"window" => "session"})
    assert html =~ "All ledger rows in this database"
    assert html =~ "$12.25"
  end

  test "spend window chips emit aria-pressed true and false", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ ~r/phx-value-window="session"[^>]*aria-pressed="true"/
    assert html =~ ~r/phx-value-window="24h"[^>]*aria-pressed="false"/
    assert html =~ ~r/phx-value-window="7d"[^>]*aria-pressed="false"/

    html = render_click(view, "set_window", %{"window" => "24h"})
    assert html =~ ~r/phx-value-window="session"[^>]*aria-pressed="false"/
    assert html =~ ~r/phx-value-window="24h"[^>]*aria-pressed="true"/
    assert html =~ ~r/phx-value-window="7d"[^>]*aria-pressed="false"/
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

    %{socket: socket} = :sys.get_state(view.pid)
    timer = socket.assigns.reload_timer
    assert is_reference(timer)

    # Further ticks must not schedule a second timer (coalesce, not reset).
    for i <- 6..10 do
      send(view.pid, {:orchestrator_status, %{running: i, claimed: 0, retrying: 0, completed: 0}})
    end

    %{socket: socket2} = :sys.get_state(view.pid)
    assert socket2.assigns.reload_timer == timer

    # Fire the coalesced reload without sleeping the suite.
    _ = Process.cancel_timer(timer)
    send(view.pid, :coalesced_dashboard_reload)
    %{socket: socket3} = :sys.get_state(view.pid)
    assert socket3.assigns.reload_timer == nil

    html = render(view)
    assert html =~ "Waiting on humans"
    assert html =~ "Dashboard"
  end

  test "roster shows 24h estimated cost and retry n/a when attempts are zero", %{conn: conn} do
    task =
      KanbanBridge.create_task(%{
        title: "Roster spend",
        status: "done",
        assignee: "demo"
      })

    Usage.append(%{
      run_id: "run_roster_1",
      task_id: task.id,
      source: "worker",
      provider: "openrouter",
      model_id: "unknown-model",
      prompt_tokens: 0,
      completion_tokens: 0,
      estimated: true
    })

    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "24h wall-clock cost"
    assert html =~ "est."
    assert html =~ "/ 24h"
    assert html =~ "retry n/a"
  end

  test "roster shows retry share when a task has been retried", %{conn: conn} do
    KanbanBridge.create_task(%{title: "First try", status: "done", assignee: "demo"})
    retried = KanbanBridge.create_task(%{title: "Retried", status: "done", assignee: "demo"})
    KanbanBridge.update_attempts(retried.id, 1)

    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "retry 1/2"
    refute html =~ "retry n/a"
  end
end
