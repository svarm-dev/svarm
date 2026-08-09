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

    unless Svarm.Board.instance_status().setup_complete? do
      assert html =~ "Open setup"
    end
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

  test "auth configured without credentials blocks approve", %{conn: conn} do
    prev_auth = Application.get_env(:svarm, :approvals_auth)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    on_exit(fn ->
      if prev_auth == nil,
        do: Application.delete_env(:svarm, :approvals_auth),
        else: Application.put_env(:svarm, :approvals_auth, prev_auth)
    end)

    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Auth gate",
        status: Approval.pending_status(),
        assignee: "demo"
      })

    {:ok, view, _html} = live(conn, ~p"/board")
    view |> element("button", "Approve") |> render_click()

    assert render(view) =~ "Authentication required"
    assert KanbanBridge.get_task(task.id).status == Approval.pending_status()
  end

  test "auth configured with valid Basic Auth allows approve", %{conn: conn} do
    prev_auth = Application.get_env(:svarm, :approvals_auth)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    on_exit(fn ->
      if prev_auth == nil,
        do: Application.delete_env(:svarm, :approvals_auth),
        else: Application.put_env(:svarm, :approvals_auth, prev_auth)
    end)

    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Auth ok",
        status: Approval.pending_status(),
        assignee: "demo"
      })

    creds = Base.encode64("op:secret")

    {:ok, view, _html} =
      conn
      |> put_req_header("authorization", "Basic #{creds}")
      |> live(~p"/board")

    view |> element("button", "Approve") |> render_click()
    assert KanbanBridge.get_task(task.id).status == "todo"
  end

  test "sticky board auth: session proof survives header-less follow-up", %{conn: conn} do
    prev_auth = Application.get_env(:svarm, :approvals_auth)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    on_exit(fn ->
      if prev_auth == nil,
        do: Application.delete_env(:svarm, :approvals_auth),
        else: Application.put_env(:svarm, :approvals_auth, prev_auth)
    end)

    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Sticky auth",
        status: Approval.pending_status(),
        assignee: "demo"
      })

    creds = Base.encode64("op:secret")

    # First request establishes session board_auth_ok
    conn =
      conn
      |> put_req_header("authorization", "Basic #{creds}")
      |> get(~p"/board")

    assert html_response(conn, 200)

    # Recycle keeps session; no Authorization header on follow-up
    {:ok, view, _html} = live(recycle(conn), ~p"/board")
    view |> element("button", "Approve") |> render_click()
    assert KanbanBridge.get_task(task.id).status == "todo"
  end

  test "auth configured without credentials blocks reject and complete_review", %{conn: conn} do
    prev_auth = Application.get_env(:svarm, :approvals_auth)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    on_exit(fn ->
      if prev_auth == nil,
        do: Application.delete_env(:svarm, :approvals_auth),
        else: Application.put_env(:svarm, :approvals_auth, prev_auth)
    end)

    KanbanBridge.delete_all_tasks()

    pending =
      KanbanBridge.create_task(%{
        title: "Reject blocked",
        status: Approval.pending_status(),
        assignee: "demo"
      })

    review =
      KanbanBridge.create_task(%{
        title: "Done blocked",
        status: "review",
        assignee: "demo"
      })

    {:ok, view, _html} = live(conn, ~p"/board")

    render_click(view, "reject_task", %{"id" => pending.id})
    assert render(view) =~ "Authentication required"
    assert KanbanBridge.get_task(pending.id).status == Approval.pending_status()

    render_click(view, "complete_review", %{"id" => review.id})
    assert render(view) =~ "Authentication required"
    assert KanbanBridge.get_task(review.id).status == "review"
  end

  test "auth configured with Basic Auth allows reject and complete_review", %{conn: conn} do
    prev_auth = Application.get_env(:svarm, :approvals_auth)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    on_exit(fn ->
      if prev_auth == nil,
        do: Application.delete_env(:svarm, :approvals_auth),
        else: Application.put_env(:svarm, :approvals_auth, prev_auth)
    end)

    KanbanBridge.delete_all_tasks()

    pending =
      KanbanBridge.create_task(%{
        title: "Reject ok",
        status: Approval.pending_status(),
        assignee: "demo"
      })

    review =
      KanbanBridge.create_task(%{
        title: "Done ok",
        status: "review",
        assignee: "demo"
      })

    creds = Base.encode64("op:secret")

    {:ok, view, _html} =
      conn
      |> put_req_header("authorization", "Basic #{creds}")
      |> live(~p"/board")

    render_click(view, "reject_task", %{"id" => pending.id})
    assert KanbanBridge.get_task(pending.id).status == "failed"

    render_click(view, "complete_review", %{"id" => review.id})
    assert KanbanBridge.get_task(review.id).status == "done"
  end

  test "prod-like without APPROVALS_* blocks approve reject and complete_review", %{conn: conn} do
    prev_auth = Application.get_env(:svarm, :approvals_auth)
    prev_dev = Application.get_env(:svarm, :dev_routes)
    Application.delete_env(:svarm, :approvals_auth)
    Application.put_env(:svarm, :dev_routes, false)

    on_exit(fn ->
      if prev_auth == nil,
        do: Application.delete_env(:svarm, :approvals_auth),
        else: Application.put_env(:svarm, :approvals_auth, prev_auth)

      Application.put_env(:svarm, :dev_routes, prev_dev)
    end)

    KanbanBridge.delete_all_tasks()

    pending =
      KanbanBridge.create_task(%{
        title: "Prod fail-closed approve",
        status: Approval.pending_status(),
        assignee: "demo"
      })

    review =
      KanbanBridge.create_task(%{
        title: "Prod fail-closed done",
        status: "review",
        assignee: "demo"
      })

    {:ok, view, _html} = live(conn, ~p"/board")

    view |> element("button", "Approve") |> render_click()
    assert render(view) =~ "APPROVALS_USER"
    assert KanbanBridge.get_task(pending.id).status == Approval.pending_status()

    render_click(view, "reject_task", %{"id" => pending.id})
    assert render(view) =~ "APPROVALS_USER"
    assert KanbanBridge.get_task(pending.id).status == Approval.pending_status()

    render_click(view, "complete_review", %{"id" => review.id})
    assert render(view) =~ "APPROVALS_USER"
    assert KanbanBridge.get_task(review.id).status == "review"
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
    assert html =~ "Mark done"
    assert html =~ "No PR on the local board"
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
    # Avoid race with the shared Orchestrator: a poll can move an untrusted
    # "demo" todo into pending_approval (or dispatch a trusted agent), emptying
    # the todo column and resurfacing the empty hint mid-test.
    # Pin max_concurrent to 0 so dispatch/gating is a no-op for this assertion.
    Svarm.Test.OrchestratorEnv.restore_on_exit()
    Application.put_env(:svarm, :orchestrator_poll_interval_ms, 60_000)
    Application.put_env(:svarm, :orchestrator_max_concurrent, 0)

    if Process.whereis(Svarm.Orchestrator) do
      assert {:ok, _} = Svarm.Orchestrator.reload_config()
    end

    KanbanBridge.delete_all_tasks()
    # Trusted assignee: even if a leftover tick fires before pin applies, the
    # approval gate will not rehome this card out of todo.
    KanbanBridge.create_task(%{title: "Fill todo", status: "todo", assignee: "default"})

    {:ok, _view, html} = live(conn, ~p"/board")

    assert html =~ "Fill todo"
    assert html =~ "Nothing running"
    assert html =~ "No completed tasks"
    assert html =~ "No failures"

    refute html =~ "Task queue",
           "todo column should not show the empty hint when it has a task"
  end

  test "selecting a running task focuses the run console", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Live run",
        status: "in_progress",
        assignee: "demo"
      })

    {:ok, view, _html} = live(conn, ~p"/board")

    # Simulate orchestrator running state so task_running? is true
    send(
      view.pid,
      {:orchestrator_status,
       %{
         running: 1,
         claimed: 0,
         retrying: 0,
         running_ids: [task.id],
         retry_ids: [],
         running_started: %{task.id => System.monotonic_time(:millisecond)}
       }}
    )

    :sys.get_state(view.pid)
    render_click(view, "select_task", %{"id" => task.id})
    html = render(view)

    assert html =~ ~s(id="run-console")
    assert html =~ ~s(data-focused="true")
    assert html =~ ~s(id="run-log")
    assert html =~ "no usage yet"
  end

  test "attach deep link selects task and focuses console", %{conn: conn} do
    KanbanBridge.delete_all_tasks()
    task = KanbanBridge.create_task(%{title: "Attach me", status: "todo", assignee: "demo"})

    {:ok, _view, html} = live(conn, ~p"/board?task=#{task.id}&attach=1")

    assert html =~ "Attach me"
    assert html =~ task.id
    assert html =~ ~s(data-focused="true")
    assert html =~ ~s(id="run-log")
  end

  test "late join restores RunLog history then live lines append", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Late join",
        status: "in_progress",
        assignee: "demo"
      })

    # History written before any board (Events single-writer path)
    Events.broadcast_agent_line(task.id, "[history] prior line\n")

    {:ok, view, _html} = live(conn, ~p"/board")
    render_click(view, "select_task", %{"id" => task.id})

    html = render(view)
    assert html =~ "[history] prior line"

    Events.broadcast_agent_line(task.id, "[live] new line\n")
    :sys.get_state(view.pid)

    html = render(view)
    assert html =~ "[history] prior line"
    assert html =~ "[live] new line"
  end

  test "stream append after select appears in console", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Stream me",
        status: "in_progress",
        assignee: "demo"
      })

    {:ok, view, _html} = live(conn, ~p"/board")
    render_click(view, "select_task", %{"id" => task.id})

    Events.broadcast_agent_line(task.id, "streamed chunk\n")
    :sys.get_state(view.pid)

    assert render(view) =~ "streamed chunk"
  end

  test "board columns use LiveView streams for task cards", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Streamed card",
        status: "todo",
        assignee: "demo",
        body: String.duplicate("SECRET_BODY_PAYLOAD ", 50)
      })

    {:ok, view, html} = live(conn, ~p"/board")

    assert html =~ ~s(id="col-todo-tasks")
    assert html =~ ~s(phx-update="stream")
    assert html =~ "Streamed card"
    assert has_element?(view, "#task-#{task.id}")
    # Full issue body must not appear in the board DOM
    refute html =~ "SECRET_BODY_PAYLOAD"
  end

  test "Board.list_tasks omits body on card projection", %{conn: conn} do
    _ = conn
    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Has body",
        status: "todo",
        assignee: "demo",
        body: "full issue body for agents only"
      })

    listed = Svarm.Board.list_tasks()
    assert Enum.any?(listed, &(&1.id == task.id))
    card = Enum.find(listed, &(&1.id == task.id))
    refute Map.get(card, :body) in ["full issue body for agents only"]
    # get_task still returns body for dispatch / detail paths
    full = Svarm.Board.get_task(task.id)
    assert full.body == "full issue body for agents only"
  end

  test "task_updated moves card between column streams", %{conn: conn} do
    KanbanBridge.delete_all_tasks()

    task =
      KanbanBridge.create_task(%{
        title: "Moving card",
        status: "todo",
        assignee: "demo"
      })

    {:ok, view, html} = live(conn, ~p"/board")
    assert html =~ "Moving card"

    Events.broadcast_task_updated(%{id: task.id, status: "in_progress", title: "Moving card"})
    :sys.get_state(view.pid)

    html = render(view)
    assert html =~ "Moving card"
    assert has_element?(view, "#task-#{task.id}")
  end
end
