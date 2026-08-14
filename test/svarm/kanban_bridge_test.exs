defmodule Svarm.KanbanBridgeTest do
  use ExUnit.Case, async: false

  alias Svarm.KanbanBridge

  setup do
    KanbanBridge.delete_all_tasks()
    on_exit(fn -> KanbanBridge.delete_all_tasks() end)
    :ok
  end

  describe "create_task/1 and get_task/1" do
    test "creates a task with generated id and defaults" do
      task =
        KanbanBridge.create_task(%{
          title: "Bridge create",
          body: "do the thing",
          type: "research",
          assignee: "demo",
          status: "todo",
          priority: 2,
          tenant: "test"
        })

      assert is_binary(task.id)
      assert String.starts_with?(task.id, "sva_")
      assert task.title == "Bridge create"
      assert task.body == "do the thing"
      assert task.type == "research"
      assert task.assignee == "demo"
      assert task.status == "todo"
      assert task.priority == 2
      assert task.attempts == 0
      assert task.depends_on == []
      assert task.tenant == "test"
      assert is_integer(task.created_at)

      assert KanbanBridge.get_task(task.id) == task
    end

    test "get_task returns nil for unknown id" do
      assert KanbanBridge.get_task("sva_does_not_exist") == nil
    end
  end

  describe "list_tasks/1" do
    test "returns all tasks ordered by priority then created_at" do
      low = KanbanBridge.create_task(%{title: "low", status: "todo", priority: 5})
      high = KanbanBridge.create_task(%{title: "high", status: "todo", priority: 1})
      mid = KanbanBridge.create_task(%{title: "mid", status: "in_progress", priority: 3})

      ids = Enum.map(KanbanBridge.list_tasks([]), & &1.id)
      assert ids == [high.id, mid.id, low.id]
    end

    test "filters by field equality" do
      KanbanBridge.create_task(%{title: "a", status: "todo", assignee: "demo"})
      KanbanBridge.create_task(%{title: "b", status: "review", assignee: "demo"})
      KanbanBridge.create_task(%{title: "c", status: "todo", assignee: "default"})

      todos = KanbanBridge.list_tasks(status: "todo")
      assert Enum.map(todos, & &1.title) |> Enum.sort() == ["a", "c"]

      demos = KanbanBridge.list_tasks(assignee: "demo")
      assert Enum.map(demos, & &1.title) |> Enum.sort() == ["a", "b"]
    end
  end

  describe "fetch_eligible/1" do
    test "returns only tasks whose status is in active_states" do
      todo = KanbanBridge.create_task(%{title: "todo", status: "todo", assignee: "demo"})

      active =
        KanbanBridge.create_task(%{title: "active", status: "in_progress", assignee: "demo"})

      _review = KanbanBridge.create_task(%{title: "review", status: "review", assignee: "demo"})
      _done = KanbanBridge.create_task(%{title: "done", status: "done", assignee: "demo"})

      eligible = KanbanBridge.fetch_eligible(["todo", "in_progress"])
      ids = Enum.map(eligible, & &1.id) |> MapSet.new()

      assert MapSet.member?(ids, todo.id)
      assert MapSet.member?(ids, active.id)
      assert MapSet.size(ids) == 2
    end
  end

  describe "update_status/2 and update_attempts/2" do
    test "updates status and attempts on an existing task" do
      task = KanbanBridge.create_task(%{title: "mutate", status: "todo", assignee: "demo"})

      assert :ok = KanbanBridge.update_status(task.id, "in_progress")
      assert %{status: "in_progress", attempts: 0} = KanbanBridge.get_task(task.id)

      assert :ok = KanbanBridge.update_attempts(task.id, 2)
      assert %{status: "in_progress", attempts: 2} = KanbanBridge.get_task(task.id)

      assert :ok = KanbanBridge.update_status(task.id, "review")
      assert %{status: "review", attempts: 2} = KanbanBridge.get_task(task.id)
    end

    test "update_status is a no-op for missing ids" do
      assert :ok = KanbanBridge.update_status("sva_missing", "failed")
    end
  end

  describe "update_depends_on/2 and delete_all_tasks/0" do
    test "stores dependency ids and clears the board" do
      a = KanbanBridge.create_task(%{title: "dep a", status: "todo"})
      b = KanbanBridge.create_task(%{title: "dep b", status: "todo"})

      assert :ok = KanbanBridge.update_depends_on(b.id, [a.id])
      assert %{depends_on: deps} = KanbanBridge.get_task(b.id)
      assert deps == [a.id]

      assert :ok = KanbanBridge.delete_all_tasks()
      assert KanbanBridge.list_tasks([]) == []
      assert KanbanBridge.get_task(a.id) == nil
    end
  end

  describe "put_pending_question/2 and clear_pending_question/1" do
    test "persists wait reason and question payload, then clears" do
      task = KanbanBridge.create_task(%{title: "ask", status: "in_progress", assignee: "demo"})
      assert task.wait_reason == nil
      assert task.pending_question == nil

      assert {:ok, stored} =
               KanbanBridge.put_pending_question(task.id, %{
                 prompt: "Which fixture should I use?",
                 request_id: "q_1"
               })

      assert stored.wait_reason == "agent_question"
      assert stored.pending_question["prompt"] == "Which fixture should I use?"
      assert stored.pending_question["reason"] == "agent_question"
      assert stored.pending_question["request_id"] == "q_1"
      assert is_integer(stored.pending_question["asked_at"])

      reloaded = KanbanBridge.get_task(task.id)
      assert reloaded.wait_reason == "agent_question"
      assert reloaded.pending_question["prompt"] == "Which fixture should I use?"

      listed = KanbanBridge.list_tasks([status: "in_progress"], include_body: false)
      assert hd(listed).pending_question["prompt"] == "Which fixture should I use?"

      assert {:ok, cleared} = KanbanBridge.clear_pending_question(task.id)
      assert cleared.wait_reason == nil
      assert cleared.pending_question == nil
      assert KanbanBridge.get_task(task.id).pending_question == nil
    end

    test "rejects missing task and empty prompt" do
      task = KanbanBridge.create_task(%{title: "nope", status: "in_progress"})

      assert {:error, :not_found} =
               KanbanBridge.put_pending_question("sva_missing", %{prompt: "x"})

      assert {:error, :invalid} = KanbanBridge.put_pending_question(task.id, %{prompt: "  "})
      assert {:error, :invalid} = KanbanBridge.put_pending_question(task.id, %{})
      assert {:error, :not_found} = KanbanBridge.clear_pending_question("sva_missing")
      assert KanbanBridge.get_task(task.id).pending_question == nil
    end
  end
end
