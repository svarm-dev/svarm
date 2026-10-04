defmodule Svarm.BoardFollowUpTest do
  use ExUnit.Case, async: false

  alias Svarm.{Board, KanbanBridge}

  setup do
    KanbanBridge.delete_all_tasks()
    :ok
  end

  test "empty text is refused" do
    task = KanbanBridge.create_task(%{title: "t", status: "review", assignee: "demo"})
    assert {:error, :empty} = Board.follow_up(task.id, "   ")
    assert {:error, :empty} = Board.follow_up(task.id, "")
    assert KanbanBridge.get_task(task.id).follow_up == nil
    assert KanbanBridge.get_task(task.id).status == "review"
  end

  test "unsupported while the card is still in_progress (use Steer)" do
    task = KanbanBridge.create_task(%{title: "t", status: "in_progress", assignee: "demo"})
    assert {:error, :unsupported} = Board.follow_up(task.id, "fix tests")
  end

  test "unsupported for todo / pending_approval / done cards" do
    for status <- ["todo", "pending_approval", "done"] do
      task = KanbanBridge.create_task(%{title: "t", status: status, assignee: "demo"})
      assert {:error, :unsupported} = Board.follow_up(task.id, "fix tests")
    end
  end

  test "not found" do
    assert {:error, :not_found} = Board.follow_up("sva_missing", "fix tests")
  end

  test "review card: trims, persists follow_up, moves to todo, writes muted board line" do
    task = KanbanBridge.create_task(%{title: "t", status: "review", assignee: "demo"})
    assert :ok = Board.follow_up(task.id, "  also fix the tests  ")

    assert %{status: "todo", follow_up: "also fix the tests"} = KanbanBridge.get_task(task.id)
    # Persisted path is one-shot metadata, not the run log body.
    assert Svarm.RunLog.get(task.id) =~ "[board] follow-up queued"
  end

  test "failed card: same behavior as review" do
    task = KanbanBridge.create_task(%{title: "t", status: "failed", assignee: "demo"})
    assert :ok = Board.follow_up(task.id, "retry with a plan")

    assert %{status: "todo", follow_up: "retry with a plan"} = KanbanBridge.get_task(task.id)
    assert Svarm.RunLog.get(task.id) =~ "[board] follow-up queued"
  end

  test "local tracker round-trip: eligible fetch exposes follow_up" do
    task =
      KanbanBridge.create_task(%{
        title: "settled",
        status: "failed",
        assignee: "demo"
      })

    :ok = Board.follow_up(task.id, "recheck the fixture")

    {:ok, eligible} =
      Svarm.Tracker.Local.list_eligible(%{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      })

    [issue] = Enum.filter(eligible, &(&1.id == task.id))
    assert issue.follow_up == "recheck the fixture"
  end

  test "clearing via update_follow_up(nil) removes the note" do
    task = KanbanBridge.create_task(%{title: "t", status: "failed", assignee: "demo"})
    :ok = Board.follow_up(task.id, "will be cleared")
    assert :ok = KanbanBridge.update_follow_up(task.id, nil)
    assert KanbanBridge.get_task(task.id).follow_up == nil
  end

  test "flash_error covers follow-up reasons" do
    assert Board.follow_up_flash_error(:empty) =~ "empty"
    assert Board.follow_up_flash_error(:unsupported) =~ "Steer"
    assert Board.follow_up_flash_error(:not_found) =~ "not found"
    assert Board.follow_up_flash_error({:persist, :forbidden}) =~ "forbidden"
    assert Board.follow_up_flash_error({:status, :forbidden}) =~ "Todo"
  end
end
