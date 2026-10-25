defmodule Svarm.OrchestratorAdmissionTest do
  use ExUnit.Case, async: false

  alias Svarm.{Events, KanbanBridge, Orchestrator, Workspace}
  alias Svarm.Settings.Catalog.Store
  alias Svarm.Test.Wait

  setup do
    KanbanBridge.delete_all_tasks()
    clear_catalog()

    on_exit(fn ->
      clear_catalog()
      KanbanBridge.delete_all_tasks()
    end)

    :ok
  end

  test "two boards with the same external id do not share a task, workspace, or running key" do
    root = workspace_root()
    insert_boards([board("alpha"), board("beta"), board("off", enabled: false)])

    alpha = task("alpha", "EXT-1", "alpha same external")
    beta = task("beta", "EXT-1", "beta same external")
    off = task("off", "EXT-1", "disabled board")

    original = :sys.get_state(Orchestrator)
    :sys.replace_state(Orchestrator, fn state -> dispatch_state(state, root, 4) end)

    try do
      Events.subscribe()
      send(Orchestrator, :tick)
      flush()

      assert wait_until(fn ->
               state = :sys.get_state(Orchestrator)

               Map.has_key?(state.running, {"alpha", "EXT-1"}) and
                 Map.has_key?(state.running, {"beta", "EXT-1"}) and
                 File.dir?(Path.join([root, "alpha", alpha.id])) and
                 File.dir?(Path.join([root, "beta", beta.id]))
             end)

      state = :sys.get_state(Orchestrator)
      refute Map.has_key?(state.running, "EXT-1")
      refute Map.has_key?(state.running, {"off", "EXT-1"})
      refute MapSet.member?(state.claimed, "EXT-1")

      rows = KanbanBridge.list_tasks(external_task_id: "EXT-1")
      assert Enum.sort(Enum.map(rows, & &1.board_id)) == ["alpha", "beta", "off"]
      assert KanbanBridge.get_task(alpha.id).workspace_locator == "alpha/#{alpha.id}"
      assert KanbanBridge.get_task(beta.id).workspace_locator == "beta/#{beta.id}"
      refute File.dir?(Path.join(root, "EXT-1"))
      refute File.dir?(Path.join([root, "off", off.id]))

      assert wait_until(fn ->
               "alpha" in Orchestrator.status().board_ids and
                 "beta" in Orchestrator.status().board_ids
             end)

      assert_receive {:orchestrator_status, %{board_ids: ids}} when is_list(ids)
      assert "alpha" in ids
      assert "beta" in ids
    after
      restore(original)
    end
  end

  test "instance cap blocks a new admit and leaves the running task running" do
    root = workspace_root()
    insert_boards([board("alpha"), board("beta")])
    alpha = task("alpha", "EXT-1", "already running", "in_progress")
    _beta = task("beta", "EXT-1", "other board")

    worker = spawn(fn -> Process.sleep(:infinity) end)
    original = :sys.get_state(Orchestrator)

    :sys.replace_state(Orchestrator, fn state ->
      state = dispatch_state(state, root, 1)

      entry = %{
        task: alpha,
        pid: worker,
        mref: Process.monitor(worker),
        board_id: "alpha",
        tracker: state.tracker,
        tracker_config: state.tracker_config,
        started_mono_ms: System.monotonic_time(:millisecond),
        started_at: System.system_time(:second)
      }

      %{
        state
        | running: Map.put(state.running, {"alpha", "EXT-1"}, entry),
          claimed: MapSet.put(state.claimed, {"alpha", "EXT-1"})
      }
    end)

    try do
      send(Orchestrator, :tick)
      flush()

      state = :sys.get_state(Orchestrator)
      assert Map.has_key?(state.running, {"alpha", "EXT-1"})
      refute Map.has_key?(state.running, {"beta", "EXT-1"})
      refute Map.has_key?(state.running, "EXT-1")
      assert Process.alive?(worker)
      assert state.running[{"alpha", "EXT-1"}].pid == worker
    after
      restore(original)
    end
  end

  test "a board cap blocks only that board" do
    root = workspace_root()
    insert_boards([board("alpha", max_concurrent: 1), board("beta")])
    alpha = task("alpha", "EXT-A", "alpha running", "in_progress")
    _alpha_next = task("alpha", "EXT-A2", "alpha blocked")
    beta = task("beta", "EXT-B", "beta free")

    worker = spawn(fn -> Process.sleep(:infinity) end)
    original = :sys.get_state(Orchestrator)

    :sys.replace_state(Orchestrator, fn state ->
      state = dispatch_state(state, root, 5)

      entry = %{
        task: alpha,
        pid: worker,
        mref: Process.monitor(worker),
        board_id: "alpha",
        tracker: state.tracker,
        tracker_config: state.tracker_config,
        started_mono_ms: System.monotonic_time(:millisecond),
        started_at: System.system_time(:second)
      }

      %{
        state
        | running: Map.put(state.running, {"alpha", "EXT-A"}, entry),
          claimed: MapSet.put(state.claimed, {"alpha", "EXT-A"})
      }
    end)

    try do
      send(Orchestrator, :tick)
      flush()

      assert wait_until(fn ->
               state = :sys.get_state(Orchestrator)

               Map.has_key?(state.running, {"beta", "EXT-B"}) and
                 File.dir?(Path.join([root, "beta", beta.id]))
             end)

      state = :sys.get_state(Orchestrator)
      assert Map.has_key?(state.running, {"alpha", "EXT-A"})
      refute Map.has_key?(state.running, {"alpha", "EXT-A2"})
      assert Process.alive?(worker)
      assert state.running[{"alpha", "EXT-A"}].pid == worker
    after
      restore(original)
    end
  end

  test "no catalog revision still dispatches the current single tracker" do
    root = workspace_root()
    assert Store.latest_revision() == nil

    task =
      KanbanBridge.create_task(%{
        title: "legacy single tracker",
        status: "todo",
        assignee: "demo"
      })

    original = :sys.get_state(Orchestrator)
    :sys.replace_state(Orchestrator, fn state -> dispatch_state(state, root, 2) end)

    try do
      send(Orchestrator, :tick)
      flush()

      assert wait_until(fn ->
               state = :sys.get_state(Orchestrator)

               Map.has_key?(state.running, task.id) and
                 File.dir?(Path.join(root, Workspace.key_for_issue(task)))
             end)

      state = :sys.get_state(Orchestrator)
      assert state.catalog == nil
      refute Map.has_key?(state.running, {"default", task.id})
      assert File.dir?(Path.join(root, task.id))
      refute File.dir?(Path.join([root, "default", task.id]))
      assert KanbanBridge.get_task(task.id).workspace_locator == nil
    after
      restore(original)
    end
  end

  defp dispatch_state(state, root, max_concurrent) do
    %{
      state
      | tracker: Svarm.Tracker.Local,
        tracker_config: %{
          kind: :local,
          active_states: ["todo", "in_progress"],
          terminal_states: ["done", "failed", "review"],
          ignored_assignees: []
        },
        approval: %{mode: :off, trusted_assignees: MapSet.new()},
        agents: Map.put(state.agents, "demo", demo_agent()),
        budget_caps: %{},
        budget_mode: :hard,
        workspace_root: root,
        workspace_isolation: :path,
        max_concurrent: max_concurrent,
        stall_timeout_ms: 45 * 60_000,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        claimed: MapSet.new(),
        running: %{},
        completed: MapSet.new(),
        retry_attempts: %{},
        approved_once: MapSet.new(),
        last_budget_block: nil,
        issue_cache: %{}
    }
  end

  defp demo_agent do
    %{
      command: "sleep",
      args: ["30"],
      env: %{},
      adapter: "cli",
      display_name: "Demo",
      name: "demo",
      tools: [],
      tools_mode: :warn
    }
  end

  defp task(board_id, external_id, title, status \\ "todo") do
    KanbanBridge.create_task(%{
      title: title,
      status: status,
      assignee: "demo",
      board_id: board_id,
      external_task_id: external_id
    })
  end

  defp board(id, opts \\ []) do
    %{
      "id" => id,
      "name" => id,
      "enabled" => Keyword.get(opts, :enabled, true),
      "tracker" => %{"kind" => "local"},
      "max_concurrent" => Keyword.get(opts, :max_concurrent)
    }
  end

  defp insert_boards(boards) do
    assert {:ok, _} = Store.insert_revision(%{"boards" => boards})
  end

  defp workspace_root do
    root =
      Path.join(System.tmp_dir!(), "svarm-admit-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp restore(original) do
    running =
      case Process.whereis(Orchestrator) do
        nil -> %{}
        _pid -> :sys.get_state(Orchestrator).running
      end

    clear_catalog()

    if Process.whereis(Orchestrator) do
      :sys.replace_state(Orchestrator, fn _ -> original end)
    end

    Enum.each(running, fn {_key, entry} ->
      if is_pid(entry[:pid]) and Process.alive?(entry.pid), do: Process.exit(entry.pid, :kill)
    end)

    flush()
  end

  defp flush do
    _ = :sys.get_state(Orchestrator)
    :ok
  end

  defp wait_until(fun), do: Wait.until(fun, attempts: 120)

  defp clear_catalog do
    for table <- [
          "catalog_board_bindings",
          "catalog_boards",
          "catalog_harness_profiles",
          "catalog_toolchain_profiles",
          "catalog_provider_profiles",
          "catalog_revisions"
        ] do
      Svarm.Repo.query!("DELETE FROM #{table}")
    end
  end
end
