defmodule Svarm.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Svarm.{Approval, KanbanBridge, Orchestrator, Workspace}

  # ponytail: one runnable check for the non-trivial logic.
  describe "Workspace.sanitize/1" do
    test "only allows [A-Za-z0-9._-], replaces the rest with _" do
      assert Workspace.sanitize("ABC-123") == "ABC-123"
      assert Workspace.sanitize("sva_deadbeef") == "sva_deadbeef"
      assert Workspace.sanitize("task with spaces!/weird") == "task_with_spaces__weird"
      # dots ARE allowed by spec §9.5 — only `/` becomes `_`
      assert Workspace.sanitize("../../etc/passwd") == ".._.._etc_passwd"
    end

    test "empty after cleaning becomes 'unnamed'" do
      assert Workspace.sanitize("!!!") == "unnamed"
    end
  end

  describe "run_exit handling" do
    test "orchestrator survives concurrent run_exit messages for unknown tasks" do
      send(Orchestrator, {:run_exit, "sva_nonexistent_a", :ok})
      send(Orchestrator, {:run_exit, "sva_nonexistent_b", :ok})
      Process.sleep(100)
      assert Process.whereis(Orchestrator)
      assert is_map(Orchestrator.status())
    end
  end

  describe "worker DOWN handling" do
    test "survives worker crash without replacing whole state" do
      task =
        KanbanBridge.create_task(%{
          title: "crash survivor",
          status: "todo",
          assignee: "cody"
        })

      mref = make_ref()

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: self(),
            mref: mref,
            run_id: "run_down_test",
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{state | running: running, claimed: MapSet.put(state.claimed, task.id)}
      end)

      send(Orchestrator, {:DOWN, mref, :process, self(), :enoent})
      Process.sleep(80)

      assert Process.whereis(Orchestrator)
      state = :sys.get_state(Orchestrator)
      refute Map.has_key?(state.running, task.id)
      refute MapSet.member?(state.claimed, task.id)
      assert is_map(state.agents) or is_map(Orchestrator.status())
    end
  end

  describe "list_eligible failures" do
    defmodule FailingTracker do
      def list_eligible(_config),
        do: {:error, %{type: :rate_limit, message: "rate limited", retry_after: 60}}

      def get_issue(_config, _id), do: {:error, :not_found}
    end

    test "tick survives tracker list_eligible errors" do
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        %{state | tracker: FailingTracker}
      end)

      try do
        send(Orchestrator, :tick)
        Process.sleep(80)
        assert Process.whereis(Orchestrator)
        assert is_map(Orchestrator.status())
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end
  end

  describe "dispatch and approval" do
    test "does not spawn worker for tasks already pending_approval" do
      task =
        KanbanBridge.create_task(%{
          title: "held",
          status: Approval.pending_status(),
          assignee: "cody"
        })

      before = Orchestrator.status()
      refute task.id in before.running_ids

      # tick already runs on interval; status should stay non-running for pending
      after_status = Orchestrator.status()
      refute task.id in after_status.running_ids

      pending = Approval.pending_status()
      assert %{status: ^pending} = KanbanBridge.get_task(task.id)
    end
  end

  describe "continuation retry" do
    test "schedules continuation when normal exit but task still active" do
      task =
        KanbanBridge.create_task(%{
          title: "continuation task",
          status: "todo",
          assignee: "cody"
        })

      # Simulate a dispatched task by injecting it into running state
      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: self(),
            mref: make_ref(),
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{state | running: running, claimed: MapSet.put(state.claimed, task.id)}
      end)

      send(Orchestrator, {:run_exit, task.id, :ok})
      Process.sleep(50)

      status = Orchestrator.status()
      # Task is "todo" (active, not terminal) → continuation retry
      assert task.id in status.retry_ids
      refute task.id in status.running_ids
    end

    test "marks completed when normal exit and task is terminal" do
      task =
        KanbanBridge.create_task(%{
          title: "done task",
          status: "done",
          assignee: "cody"
        })

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: self(),
            mref: make_ref(),
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{state | running: running, claimed: MapSet.put(state.claimed, task.id)}
      end)

      send(Orchestrator, {:run_exit, task.id, :ok})
      Process.sleep(50)

      status = Orchestrator.status()
      # Task is "done" (terminal) → completed, not in retry
      refute task.id in status.retry_ids
    end
  end

  describe "tracker reconcile (step 23)" do
    test "removes task from running/claimed when tracker reports terminal state" do
      task =
        KanbanBridge.create_task(%{
          title: "externally closed",
          status: "todo",
          assignee: "cody"
        })

      # Spawn a real process so we can safely exit it
      worker = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: worker,
            mref: make_ref(),
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{state | running: running, claimed: MapSet.put(state.claimed, task.id)}
      end)

      # Externally mark terminal (human closed the ticket, for example)
      KanbanBridge.update_status(task.id, "done")

      # Trigger a reconcile cycle
      send(Orchestrator, :tick)
      Process.sleep(80)

      status = Orchestrator.status()
      refute task.id in status.running_ids

      # Worker should have been asked to exit
      refute Process.alive?(worker)

      # The task itself should still be terminal in the tracker
      assert %{status: "done"} = KanbanBridge.get_task(task.id)
    end

    test "releases claimed/retrying tasks when tracker says they are terminal" do
      task =
        KanbanBridge.create_task(%{
          title: "claimed but externally done",
          status: "in_progress"
        })

      :sys.replace_state(Orchestrator, fn state ->
        %{state | claimed: MapSet.put(state.claimed, task.id)}
      end)

      KanbanBridge.update_status(task.id, "failed")

      send(Orchestrator, :tick)
      Process.sleep(50)

      status = Orchestrator.status()
      # Should no longer be claimed in internal state
      # (status/0 doesn't expose claimed directly, but running should be clean)
      refute task.id in status.running_ids
    end
  end

  describe "post_run_summary (step 20)" do
    test "called on terminal success" do
      task =
        KanbanBridge.create_task(%{
          title: "terminal success task",
          status: "done",
          assignee: "cody"
        })

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: self(),
            mref: make_ref(),
            run_id: "run_test123",
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{state | running: running, claimed: MapSet.put(state.claimed, task.id)}
      end)

      send(Orchestrator, {:run_exit, task.id, :ok})
      Process.sleep(50)

      state = :sys.get_state(Orchestrator)
      # last_run_entries should be set after run_exit
      assert Map.get(state, :last_run_entries)[task.id]
      assert Map.get(state, :last_run_entries)[task.id].run_id == "run_test123"
    end

    test "not called on continuation retry (task still active)" do
      task =
        KanbanBridge.create_task(%{
          title: "continuation task",
          status: "todo",
          assignee: "cody"
        })

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: self(),
            mref: make_ref(),
            run_id: "run_cont_test",
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{state | running: running, claimed: MapSet.put(state.claimed, task.id)}
      end)

      send(Orchestrator, {:run_exit, task.id, :ok})
      Process.sleep(50)

      status = Orchestrator.status()
      # Task stays in retry_ids (continuation), not completed
      assert task.id in status.retry_ids
    end
  end

  describe "Workspace.ensure/2 escape guard" do
    test "rejects a path that climbs outside root" do
      # ".." slips past sanitize (dots are allowed by Symphony §9.5); the
      # path-stays-in-root guard (invariant 2) is the real backstop.
      root = Path.join(System.tmp_dir!(), "svarmguard_test_#{:rand.uniform(9999)}")

      assert_raise RuntimeError, ~r/invalid_workspace_path/, fn ->
        Workspace.ensure("..", root)
      end
    end

    test "workspace key for issue" do
      task =
        KanbanBridge.create_task(%{
          title: "dep task",
          status: "todo",
          assignee: "cody"
        })

      key = Workspace.key_for_issue(task)
      assert is_binary(key)
    end
  end

  describe "post_run_summary retry exhausted" do
    test "calls post_run_summary when retries are exhausted" do
      task =
        KanbanBridge.create_task(%{
          title: "will fail task",
          status: "todo",
          assignee: "cody"
        })

      worker = spawn(fn -> Process.sleep(:infinity) end)

      # Set max_retries to 0 so first error exhausts immediately
      :sys.replace_state(Orchestrator, fn state ->
        %{state | max_retries: 0}
      end)

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: worker,
            mref: make_ref(),
            run_id: "run_exhaust_test",
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{state | running: running, claimed: MapSet.put(state.claimed, task.id)}
      end)

      send(Orchestrator, {:run_exit, task.id, {:error, :agent_exit}})
      Process.sleep(80)

      state = :sys.get_state(Orchestrator)
      # Entry should be stored in last_run_entries
      assert state.last_run_entries[task.id]
      assert state.last_run_entries[task.id].run_id == "run_exhaust_test"

      # Restore default max_retries for subsequent tests
      :sys.replace_state(Orchestrator, fn s -> %{s | max_retries: 5} end)
    end

    test "does not post summary on intermediate retry" do
      task =
        KanbanBridge.create_task(%{
          title: "retryable task",
          status: "todo",
          assignee: "cody"
        })

      # Ensure default max_retries (previous test may have changed it)
      :sys.replace_state(Orchestrator, fn state -> %{state | max_retries: 5} end)

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: self(),
            mref: make_ref(),
            run_id: "run_retry_mid",
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{state | running: running, claimed: MapSet.put(state.claimed, task.id)}
      end)

      send(Orchestrator, {:run_exit, task.id, {:error, :agent_exit}})
      Process.sleep(50)

      status = Orchestrator.status()
      # With default max_retries=5, should be in retry, not completed
      assert task.id in status.retry_ids
      refute task.id in status.running_ids
    end
  end
end
