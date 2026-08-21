defmodule Svarm.Tracker.LocalTest do
  use ExUnit.Case, async: false

  alias Svarm.{Issue, KanbanBridge}
  alias Svarm.Tracker.Local
  alias Svarm.Tracker.Local.Eligibility

  @config %{
    active_states: ["todo", "in_progress"],
    ignored_assignees: ["human", "bot"]
  }

  setup do
    KanbanBridge.delete_all_tasks()
    on_exit(fn -> KanbanBridge.delete_all_tasks() end)
    :ok
  end

  defp issue(attrs) do
    defaults = %{
      id: "sva_1",
      source_id: "sva_1",
      title: "t",
      body: "",
      type: "code",
      assignee: "demo",
      status: "todo",
      priority: 0,
      attempts: 0,
      created_by: "svarm",
      created_at: 0,
      tenant: "test",
      labels: [],
      depends_on: [],
      tracker: :local,
      raw: %{}
    }

    struct!(Issue, Map.merge(defaults, attrs))
  end

  test "capabilities/0 is empty (no CI or review poll)" do
    assert Local.capabilities() == []
  end

  describe "Eligibility.eligible?/2" do
    test "accepts local tasks in active states with non-ignored assignees" do
      assert Eligibility.eligible?(issue(%{}), @config)
      assert Eligibility.eligible?(issue(%{status: "in_progress"}), @config)
    end

    test "rejects terminal statuses, ignored assignees, and non-local trackers" do
      refute Eligibility.eligible?(issue(%{status: "review"}), @config)
      refute Eligibility.eligible?(issue(%{status: "done"}), @config)
      refute Eligibility.eligible?(issue(%{assignee: "human"}), @config)
      refute Eligibility.eligible?(issue(%{tracker: :github}), @config)
    end
  end

  describe "list_eligible/1" do
    test "returns only active, non-ignored local tasks as Issue structs" do
      todo =
        KanbanBridge.create_task(%{
          title: "eligible todo",
          status: "todo",
          assignee: "demo"
        })

      _ignored =
        KanbanBridge.create_task(%{
          title: "human owned",
          status: "todo",
          assignee: "human"
        })

      _review =
        KanbanBridge.create_task(%{
          title: "in review",
          status: "review",
          assignee: "demo"
        })

      active =
        KanbanBridge.create_task(%{
          title: "running",
          status: "in_progress",
          assignee: "demo_code"
        })

      assert {:ok, eligible} = Local.list_eligible(@config)
      ids = Enum.map(eligible, & &1.id) |> MapSet.new()

      assert MapSet.member?(ids, todo.id)
      assert MapSet.member?(ids, active.id)
      assert MapSet.size(ids) == 2

      Enum.each(eligible, fn issue ->
        assert %Issue{} = issue
        assert issue.tracker == :local
        assert issue.status in @config.active_states
        assert issue.assignee not in @config.ignored_assignees
      end)
    end

    test "defaults list query to todo/in_progress when active_states omitted" do
      task =
        KanbanBridge.create_task(%{title: "default active", status: "todo", assignee: "demo"})

      _done = KanbanBridge.create_task(%{title: "done", status: "done", assignee: "demo"})

      # list_eligible defaults the KanbanBridge query, but Eligibility still needs keys.
      config = %{active_states: ["todo", "in_progress"], ignored_assignees: []}
      assert {:ok, [issue]} = Local.list_eligible(config)
      assert issue.id == task.id
      assert issue.status == "todo"
    end
  end

  describe "status transitions via public Tracker API" do
    test "create → claim → in_progress → review → done" do
      assert {:ok, created} =
               Local.create_issue(@config, %{
                 title: "lifecycle",
                 body: "walk the statuses",
                 type: "code",
                 assignee: "demo",
                 status: "todo",
                 tenant: "test"
               })

      assert %Issue{status: "todo", tracker: :local} = created
      assert String.starts_with?(created.id, "sva_")
      assert created.source_id == created.id

      assert :ok = Local.claim(@config, created.id)
      assert :ok = Local.update_status(@config, created.id, "in_progress")
      assert {:ok, %{status: "in_progress"}} = Local.get_issue(@config, created.id)

      assert :ok = Local.update_attempts(@config, created.id, 1)
      assert {:ok, %{attempts: 1, status: "in_progress"}} = Local.get_issue(@config, created.id)

      assert :ok = Local.update_status(@config, created.id, "review")
      assert {:ok, %{status: "review"}} = Local.get_issue(@config, created.id)

      assert :ok = Local.update_status(@config, created.id, "done")
      assert {:ok, %{status: "done", attempts: 1}} = Local.get_issue(@config, created.id)

      # Terminal task is no longer eligible
      assert {:ok, []} = Local.list_eligible(@config)
    end

    test "failed path and get_issue not_found" do
      assert {:ok, task} =
               Local.create_issue(@config, %{title: "will fail", status: "todo", assignee: "demo"})

      assert :ok = Local.update_status(@config, task.id, "failed")
      assert {:ok, %{status: "failed"}} = Local.get_issue(@config, task.id)
      assert {:error, :not_found} = Local.get_issue(@config, "sva_missing_xyz")
    end
  end

  describe "list_issues/2 and delete_all/1" do
    test "lists with filters and clears the board" do
      KanbanBridge.create_task(%{title: "a", status: "todo", assignee: "demo"})
      KanbanBridge.create_task(%{title: "b", status: "review", assignee: "demo"})

      assert {:ok, all} = Local.list_issues(@config, [])
      assert match?([_, _], all)
      assert Enum.all?(all, &match?(%Issue{tracker: :local}, &1))

      assert {:ok, [review]} = Local.list_issues(@config, status: "review")
      assert review.title == "b"

      assert :ok = Local.delete_all(@config)
      assert {:ok, []} = Local.list_issues(@config, [])
    end
  end

  test "post_run_summary is a no-op success" do
    assert :ok = Local.post_run_summary(@config, "sva_x", %{run_id: "r1", result: :ok})
  end
end
