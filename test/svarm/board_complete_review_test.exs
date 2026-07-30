defmodule Svarm.BoardCompleteReviewTest do
  use ExUnit.Case, async: false

  alias Svarm.{Board, KanbanBridge}

  test "complete_review moves review → done" do
    KanbanBridge.delete_all_tasks()
    task = KanbanBridge.create_task(%{title: "PR ready", status: "review", assignee: "demo"})
    assert :ok = Board.complete_review(task.id)
    assert %{status: "done"} = KanbanBridge.get_task(task.id)
  end

  test "complete_review rejects non-review status" do
    KanbanBridge.delete_all_tasks()
    task = KanbanBridge.create_task(%{title: "Still running", status: "todo", assignee: "demo"})
    assert {:error, :not_in_review} = Board.complete_review(task.id)
  end
end
