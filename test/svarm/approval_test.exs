defmodule Svarm.ApprovalTest do
  use ExUnit.Case, async: false

  alias Svarm.{Approval, Issue, KanbanBridge, Tracker}
  alias Svarm.Test.FakeTracker

  @agents %{
    "default" => %{command: "true", args: [], env: %{}},
    "cody" => %{command: "true", args: [], env: %{}}
  }

  setup do
    Approval.__clear_tracker_override__()
    # Settings overlay must not force GitHub during Local regression.
    Svarm.Settings.Store.delete("tracker")

    on_exit(fn ->
      Approval.__clear_tracker_override__()
      Svarm.Settings.Store.delete("tracker")
    end)

    :ok
  end

  describe "config_from_map/1" do
    test "parses mode and trusted assignees" do
      cfg =
        Approval.config_from_map(%{
          "approval" => %{
            "mode" => "untrusted",
            "trusted_assignees" => ["default", "cody"]
          }
        })

      assert cfg.mode == :untrusted
      assert MapSet.equal?(cfg.trusted_assignees, MapSet.new(["default", "cody"]))
    end

    test "unknown mode is off" do
      assert %{mode: :off} = Approval.config_from_map(%{"approval" => %{"mode" => "nope"}})
    end
  end

  describe "required?/3" do
    test "off never gates" do
      cfg = %{mode: :off, trusted_assignees: MapSet.new()}
      task = %{status: "todo", assignee: "cody", title: "x", body: ""}
      refute Approval.required?(cfg, task, @agents)
    end

    test "all gates todo tasks" do
      cfg = %{mode: :all, trusted_assignees: MapSet.new()}
      task = %{status: "todo", assignee: "default", title: "x", body: ""}
      assert Approval.required?(cfg, task, @agents)
    end

    test "does not gate in_progress" do
      cfg = %{mode: :all, trusted_assignees: MapSet.new()}
      task = %{status: "in_progress", assignee: "cody", title: "x", body: ""}
      refute Approval.required?(cfg, task, @agents)
    end

    test "untrusted skips trusted assignee" do
      cfg = %{mode: :untrusted, trusted_assignees: MapSet.new(["default"])}
      task = %{status: "todo", assignee: "default", title: "x", body: ""}
      refute Approval.required?(cfg, task, @agents)
    end

    test "untrusted gates non-trusted assignee" do
      cfg = %{mode: :untrusted, trusted_assignees: MapSet.new(["default"])}
      task = %{status: "todo", assignee: "cody", title: "x", body: ""}
      assert Approval.required?(cfg, task, @agents)
    end

    test "untrusted mode gates demo_code but not trusted demo_research" do
      cfg = %{
        mode: :untrusted,
        trusted_assignees: MapSet.new(["demo_research", "demo_docs"])
      }

      research = %{status: "todo", assignee: "demo_research", title: "r", body: ""}
      code = %{status: "todo", assignee: "demo_code", title: "c", body: ""}
      agents = %{"demo_research" => %{}, "demo_code" => %{}, "demo_docs" => %{}}

      refute Approval.required?(cfg, research, agents)
      assert Approval.required?(cfg, code, agents)
    end
  end

  describe "reject/2" do
    test "invalid to_status returns error tuple" do
      assert {:error, :invalid_status} = Approval.reject("sva_nope", "todo")
    end
  end

  describe "flash_error/1" do
    test "maps known errors" do
      assert Approval.flash_error(:not_found) =~ "not found"
      assert Approval.flash_error({:not_pending, "done"}) =~ "pending"
    end
  end

  describe "active tracker surface API" do
    setup do
      FakeTracker.setup()
      config = %{kind: :github, owner: "acme", repo: "widgets"}
      Approval.__override_tracker__(FakeTracker, config)

      pending = %Issue{
        id: "sva_pending",
        title: "Gate me",
        body: "",
        type: "code",
        assignee: "cody",
        status: "pending_approval",
        priority: 0,
        attempts: 0,
        labels: [],
        tracker: :github
      }

      demo = %Issue{
        id: "sva_demo",
        title: "Demo",
        body: "",
        type: "code",
        assignee: "demo_coder",
        status: "pending_approval",
        priority: 0,
        attempts: 0,
        labels: [],
        tracker: :github
      }

      other = %Issue{
        id: "sva_todo",
        title: "Not pending",
        body: "",
        type: "code",
        assignee: "cody",
        status: "todo",
        priority: 0,
        attempts: 0,
        labels: [],
        tracker: :github
      }

      FakeTracker.put(pending)
      FakeTracker.put(demo)
      FakeTracker.put(other)

      %{config: config}
    end

    test "tracker/0 returns the active adapter" do
      assert Approval.tracker() == FakeTracker
    end

    test "tracker_config/0 returns the active config", %{config: config} do
      assert Approval.tracker_config() == config
    end

    test "list_pending returns only pending_approval on the active tracker" do
      ids = Approval.list_pending() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["sva_demo", "sva_pending"]
    end

    test "approve moves pending issue to todo on the active tracker" do
      assert :ok = Approval.approve("sva_pending")
      assert {:ok, %{status: "todo"}} = FakeTracker.get_issue(%{}, "sva_pending")
    end

    test "reject moves pending issue to failed on the active tracker" do
      assert :ok = Approval.reject("sva_pending")
      assert {:ok, %{status: "failed"}} = FakeTracker.get_issue(%{}, "sva_pending")
    end

    test "reject to review is allowed" do
      assert :ok = Approval.reject("sva_pending", "review")
      assert {:ok, %{status: "review"}} = FakeTracker.get_issue(%{}, "sva_pending")
    end

    test "demo assignees can be approved when gated (code agent path)" do
      assert :ok = Approval.approve("sva_demo")
      assert {:ok, %{status: "todo"}} = FakeTracker.get_issue(%{}, "sva_demo")
    end

    test "approve of non-pending returns not_pending" do
      assert {:error, {:not_pending, "todo"}} = Approval.approve("sva_todo")
    end

    test "approve of missing issue returns not_found" do
      assert {:error, :not_found} = Approval.approve("sva_missing")
    end
  end

  describe "local tracker path" do
    setup do
      # Default resolve is Local when no override and no github settings.
      :ok = Tracker.Local.delete_all(%{})
      on_exit(fn -> Tracker.Local.delete_all(%{}) end)
      :ok
    end

    test "approve and list_pending work on Local SQLite" do
      task =
        KanbanBridge.create_task(%{
          title: "Local gate",
          body: "",
          type: "code",
          assignee: "cody",
          status: "pending_approval"
        })

      assert Approval.tracker() == Tracker.Local
      assert [%{id: id}] = Approval.list_pending()
      assert id == task.id

      assert :ok = Approval.approve(task.id)
      assert Approval.list_pending() == []
      assert %{status: "todo"} = KanbanBridge.get_task(task.id)
    end
  end
end
