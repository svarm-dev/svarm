defmodule SvarmWeb.BoardLiveTest do
  use SvarmWeb.LiveCase, async: false

  alias Svarm.{Approval, Events, KanbanBridge}

  test "empty board shows first-value onboarding without column strip", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    {:ok, _view, html} = live(conn, ~p"/board")

    assert html =~ "All quiet. No tickets yet."
    assert html =~ "per-ticket cost"
    assert html =~ "Approvals and review are the human steps"
    assert html =~ "First-run checklist"
    assert html =~ "Workflow loaded"
    refute html =~ "Needs approval"
    refute html =~ "Run detail"
  end

  test "renders board with tasks and hides empty onboarding", %{conn: conn} do
    KanbanBridge.create_task(%{title: "LV test card", status: "todo", assignee: "demo"})

    {:ok, view, html} = live(conn, ~p"/board")

    assert html =~ "Agent work"
    assert html =~ "LV test card"
    assert html =~ "Todo"
    refute html =~ "All quiet"
    refute html =~ "First-run checklist"
    assert has_element?(view, "button", "Refresh")
  end

  test "keyboard j/k and Escape select tasks", %{conn: conn} do
    KanbanBridge.delete_all_tasks()
    a = KanbanBridge.create_task(%{title: "Alpha", status: "todo", assignee: "demo"})
    b = KanbanBridge.create_task(%{title: "Beta", status: "todo", assignee: "demo"})

    {:ok, view, _html} = live(conn, ~p"/board")

    render_keydown(view, "board_keydown", %{"key" => "j"})
    assert render(view) =~ a.id

    render_keydown(view, "board_keydown", %{"key" => "j"})
    assert render(view) =~ b.id

    render_keydown(view, "board_keydown", %{"key" => "Escape"})
    assert render(view) =~ "Select a card"
  end

  test "task query param selects card", %{conn: conn} do
    KanbanBridge.delete_all_tasks()
    task = KanbanBridge.create_task(%{title: "Linked", status: "todo", assignee: "demo"})

    {:ok, _view, html} = live(conn, ~p"/board?task=#{task.id}")
    assert html =~ "Linked"
    assert html =~ task.id
  end

  test "inline approve on pending card", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Gate me",
        status: Approval.pending_status(),
        assignee: "demo"
      })

    {:ok, view, html} = live(conn, ~p"/board")

    assert html =~ "Needs approval"
    assert html =~ "Approve"

    view |> element("button", "Approve") |> render_click()

    updated = KanbanBridge.get_task(task.id)
    assert updated.status == "todo"
  end

  test "pending approval and review cards show wait chips", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    KanbanBridge.create_task(%{
      title: "Gate chip",
      status: Approval.pending_status(),
      assignee: "demo"
    })

    KanbanBridge.create_task(%{
      title: "Review chip",
      status: "review",
      assignee: "demo"
    })

    {:ok, _view, html} = live(conn, ~p"/board")

    assert html =~ "Needs approval"
    assert html =~ "Needs review"
    assert html =~ "Gate chip"
    assert html =~ "Review chip"
  end

  test "review run panel shows awaiting human callout and PR link", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Review me",
        status: "review",
        assignee: "demo"
        # pr_url is not a schema field; BoardLive reads task maps + run meta
      })

    {:ok, view, _html} = live(conn, ~p"/board")

    render_click(view, "select_task", %{"id" => task.id})
    html = render(view)

    assert html =~ "Awaiting human review"
    assert html =~ "Review on tracker/GitHub"
    refute html =~ "Open PR"
  end

  test "review run panel links Open PR when meta has pr_url", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "PR ready",
        status: "review",
        assignee: "demo"
      })

    {:ok, view, _html} = live(conn, ~p"/board")

    # Inject run meta with pr_url via PubSub (same path as run_started)
    Phoenix.PubSub.broadcast(
      Svarm.PubSub,
      Events.topic(),
      {:run_started, task.id,
       %{
         assignee: "demo",
         display_name: "Demo",
         attempt: 1,
         pr_url: "https://github.com/example/repo/pull/9"
       }}
    )

    :sys.get_state(view.pid)
    render_click(view, "select_task", %{"id" => task.id})
    html = render(view)

    assert html =~ "Awaiting human review"
    assert html =~ "Open PR"
    assert html =~ "https://github.com/example/repo/pull/9"
  end

  test "review column empty hint names human review", %{conn: conn} do
    KanbanBridge.delete_all_tasks()
    KanbanBridge.create_task(%{title: "Only todo", status: "todo", assignee: "demo"})

    {:ok, _view, html} = live(conn, ~p"/board")
    assert html =~ "No work waiting for human review"
  end

  test "handles agent_line PubSub without crashing", %{conn: conn} do
    task =
      KanbanBridge.create_task(%{
        title: "stream test",
        status: "in_progress",
        assignee: "demo"
      })

    {:ok, view, _html} = live(conn, ~p"/board")

    render_click(view, "select_task", %{"id" => task.id})

    Phoenix.PubSub.broadcast(Svarm.PubSub, Events.topic(), {:agent_line, task.id, "hello\n"})
    :sys.get_state(view.pid)

    assert render(view) =~ "hello"
  end

  test "auto-selects task on run_started when nothing selected", %{conn: conn} do
    KanbanBridge.delete_all_tasks()
    task = KanbanBridge.create_task(%{title: "Auto", status: "in_progress", assignee: "demo"})

    {:ok, view, _html} = live(conn, ~p"/board")
    # Suite noise may auto-select via concurrent run_started; start from idle.
    render_click(view, "clear_selection", %{})

    # Before broadcast: idle run panel
    assert render(view) =~ "Select a card"

    Phoenix.PubSub.broadcast(
      Svarm.PubSub,
      Events.topic(),
      {:run_started, task.id, %{assignee: "demo", display_name: "Demo", attempt: 1}}
    )

    :sys.get_state(view.pid)
    # After broadcast: task appears in run panel (idle panel gone)
    refute render(view) =~ "Select a card"
    assert render(view) =~ "Auto"
  end

  test "deselect button clears selection and returns to idle run panel", %{conn: conn} do
    KanbanBridge.delete_all_tasks()
    task = KanbanBridge.create_task(%{title: "Deselect me", status: "todo", assignee: "demo"})

    {:ok, view, _html} = live(conn, ~p"/board")

    render_click(view, "select_task", %{"id" => task.id})

    refute render(view) =~ "Select a card",
           "run panel should show task details, not idle message"

    render_click(view, "clear_selection", %{})

    assert render(view) =~ "Select a card",
           "run panel should return to idle message after deselect"
  end

  test "empty columns show contextual hints instead of dash", %{conn: conn} do
    KanbanBridge.delete_all_tasks()
    KanbanBridge.create_task(%{title: "Fill todo", status: "todo", assignee: "demo"})

    {:ok, _view, html} = live(conn, ~p"/board")

    assert html =~ "Nothing running"
    assert html =~ "No completed tasks"
    assert html =~ "No failures"

    refute html =~ "Task queue",
           "todo column should not show the empty hint when it has a task"
  end
end
