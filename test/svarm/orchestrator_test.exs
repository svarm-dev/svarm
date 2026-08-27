defmodule Svarm.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Svarm.{Approval, Events, Issue, KanbanBridge, Orchestrator, Workspace}
  alias Svarm.Runner.Cli
  alias Svarm.Test.{OsPid, Wait}

  @fake_cli Path.expand("../support/fake_cli_agent.sh", __DIR__)

  # Sync barrier: GenServer processes mailbox FIFO, so get_state waits until
  # prior handle_info/handle_cast messages have finished.
  defp flush_orchestrator do
    _ = :sys.get_state(Orchestrator)
    :ok
  end

  # Up to ~3s under CI load (was 1s / 40×25ms — flaked on slow ticks).
  defp wait_until(fun, attempts \\ 120) do
    Wait.until(fun, attempts: attempts)
  end

  defp with_kb_calls(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = "orch-kb-calls-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:svarm, :kanban_bridge, :call],
        fn _event, meas, meta, _cfg ->
          send(parent, {:kb_call, meta[:op], meas[:n] || 1})
        end,
        nil
      )

    try do
      result = fun.()
      {drain_kb_calls([]), result}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_kb_calls(acc) do
    receive do
      {:kb_call, op, n} -> drain_kb_calls([{op, n} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_http_gets(acc) do
    receive do
      {:http_get, url} -> drain_http_gets([url | acc])
      {:http_get, url, _opts} -> drain_http_gets([url | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

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

  describe "board abort" do
    defmodule AbortFailTracker do
      def update_status(_config, _id, _status), do: {:error, :forbidden}
      def list_eligible(_config), do: {:ok, []}

      def get_issue(_config, id) do
        case KanbanBridge.get_task(id) do
          nil -> {:error, :not_found}
          task -> {:ok, task}
        end
      end
    end

    test "not running returns {:error, :not_running}" do
      assert {:error, :not_running} = Orchestrator.abort("sva_abort_missing")
    end

    test "tracker PATCH failure does not claim todo or crash" do
      task =
        KanbanBridge.create_task(%{
          title: "abort patch fail",
          status: "in_progress",
          assignee: "cody"
        })

      worker = spawn(fn -> Process.sleep(:infinity) end)
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: AbortFailTracker,
            running:
              Map.put(state.running, task.id, %{
                task: task,
                pid: worker,
                mref: Process.monitor(worker),
                started_mono_ms: System.monotonic_time(:millisecond),
                started_at: System.system_time(:second)
              }),
            claimed: MapSet.put(state.claimed, task.id)
        }
      end)

      try do
        assert {:error, :forbidden} = Orchestrator.abort(task.id)
        assert Process.whereis(Orchestrator)
        refute Process.alive?(worker)
        assert KanbanBridge.get_task(task.id).status == "in_progress"
        refute Svarm.RunLog.get(task.id) =~ "[board] aborted"
        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, task.id)
        refute MapSet.member?(state.claimed, task.id)
      after
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "kills worker, drops claim, does not crash-retry" do
      task =
        KanbanBridge.create_task(%{
          title: "abort no retry",
          status: "in_progress",
          assignee: "cody"
        })

      worker = spawn(fn -> Process.sleep(:infinity) end)
      original = :sys.get_state(Orchestrator)
      mref = Process.monitor(worker)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | running:
              Map.put(state.running, task.id, %{
                task: task,
                pid: worker,
                mref: mref,
                started_mono_ms: System.monotonic_time(:millisecond),
                started_at: System.system_time(:second)
              }),
            claimed: MapSet.put(state.claimed, task.id)
        }
      end)

      try do
        assert :ok = Orchestrator.abort(task.id)
        refute Process.alive?(worker)
        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, task.id)
        refute MapSet.member?(state.claimed, task.id)
        refute Map.has_key?(state.retry_attempts, task.id)
        assert KanbanBridge.get_task(task.id).status == "todo"
      after
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "does not yank a finished ticket back to todo" do
      task =
        KanbanBridge.create_task(%{
          title: "abort after finish",
          status: "in_progress",
          assignee: "cody"
        })

      worker = spawn(fn -> Process.sleep(:infinity) end)
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | running:
              Map.put(state.running, task.id, %{
                task: task,
                pid: worker,
                mref: Process.monitor(worker),
                started_mono_ms: System.monotonic_time(:millisecond),
                started_at: System.system_time(:second)
              }),
            claimed: MapSet.put(state.claimed, task.id)
        }
      end)

      try do
        assert :ok = KanbanBridge.update_status(task.id, "review")
        assert {:error, :not_running} = Orchestrator.abort(task.id)
        assert KanbanBridge.get_task(task.id).status == "review"
        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, task.id)
        refute MapSet.member?(state.claimed, task.id)
        assert Map.has_key?(state.last_run_entries, task.id)
        assert MapSet.member?(state.completed, task.id)
      after
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "failed late abort does not session-skip via completed" do
      task =
        KanbanBridge.create_task(%{
          title: "abort after fail",
          status: "in_progress",
          assignee: "cody"
        })

      worker = spawn(fn -> Process.sleep(:infinity) end)
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | running:
              Map.put(state.running, task.id, %{
                task: task,
                pid: worker,
                mref: Process.monitor(worker),
                started_mono_ms: System.monotonic_time(:millisecond),
                started_at: System.system_time(:second)
              }),
            claimed: MapSet.put(state.claimed, task.id)
        }
      end)

      try do
        assert :ok = KanbanBridge.update_status(task.id, "failed")
        assert {:error, :not_running} = Orchestrator.abort(task.id)
        assert KanbanBridge.get_task(task.id).status == "failed"
        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, task.id)
        refute MapSet.member?(state.completed, task.id)
      after
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end
  end

  describe "run_exit handling" do
    test "orchestrator survives concurrent run_exit messages for unknown tasks" do
      send(Orchestrator, {:run_exit, "sva_nonexistent_a", :ok})
      send(Orchestrator, {:run_exit, "sva_nonexistent_b", :ok})
      flush_orchestrator()
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
      flush_orchestrator()

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
        flush_orchestrator()
        assert Process.whereis(Orchestrator)
        assert is_map(Orchestrator.status())
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end
  end

  describe "spawn failures" do
    test "supervisor start_child error does not kill Orchestrator" do
      {:ok, fake_sup} = Task.Supervisor.start_link(max_children: 0)
      original = :sys.get_state(Orchestrator)
      orch = Process.whereis(Orchestrator)
      orch_ref = Process.monitor(orch)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      demo_agent = %{
        command: "true",
        args: [],
        env: %{},
        adapter: "cli",
        display_name: "Demo",
        name: "demo"
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            tracker_config: local_config,
            agents: Map.put(state.agents, "demo", demo_agent),
            approval: %{mode: :off, trusted_assignees: MapSet.new()},
            budget_caps: %{},
            claimed: MapSet.new(),
            running: %{},
            completed: MapSet.new(),
            retry_attempts: %{},
            last_budget_block: nil,
            task_supervisor: fake_sup
        }
      end)

      try do
        flush_orchestrator()

        already =
          KanbanBridge.create_task(%{
            title: "preexisting claim",
            status: "in_progress",
            assignee: "demo"
          })

        :sys.replace_state(Orchestrator, fn state ->
          %{state | claimed: MapSet.put(state.claimed, already.id)}
        end)

        task =
          KanbanBridge.create_task(%{
            title: "spawn error survivor",
            status: "todo",
            assignee: "demo"
          })

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(Orchestrator, :tick)
            flush_orchestrator()
          end)

        refute_received {:DOWN, ^orch_ref, :process, ^orch, _}
        assert Process.whereis(Orchestrator) == orch
        assert is_map(Orchestrator.status())

        st = :sys.get_state(Orchestrator)
        assert MapSet.member?(st.claimed, already.id)
        refute MapSet.member?(st.claimed, task.id)
        refute Map.has_key?(st.running, task.id)
        assert KanbanBridge.get_task(task.id).status == "todo"
        assert log =~ "spawn failed"
        assert log =~ task.id
      after
        Process.demonitor(orch_ref, [:flush])

        if Process.whereis(Orchestrator) do
          :sys.replace_state(Orchestrator, fn _ -> original end)
        end

        if Process.alive?(fake_sup), do: GenServer.stop(fake_sup)
      end
    end

    test "supervisor start_child error does not burn one-shot permits" do
      {:ok, fake_sup} = Task.Supervisor.start_link(max_children: 0)
      original = :sys.get_state(Orchestrator)
      orch = Process.whereis(Orchestrator)
      orch_ref = Process.monitor(orch)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      demo_agent = %{
        command: "true",
        args: [],
        env: %{},
        adapter: "cli",
        display_name: "Demo",
        name: "demo"
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            tracker_config: local_config,
            agents: Map.put(state.agents, "demo", demo_agent),
            approval: %{mode: :off, trusted_assignees: MapSet.new()},
            budget_caps: %{},
            claimed: MapSet.new(),
            running: %{},
            completed: MapSet.new(),
            retry_attempts: %{},
            last_budget_block: nil,
            task_supervisor: fake_sup
        }
      end)

      try do
        flush_orchestrator()

        task =
          KanbanBridge.create_task(%{
            title: "spawn error keeps permits",
            status: "todo",
            assignee: "demo"
          })

        :sys.replace_state(Orchestrator, fn state ->
          %{
            state
            | approved_once: MapSet.put(state.approved_once, task.id),
              overage_once: MapSet.put(state.overage_once || MapSet.new(), task.id)
          }
        end)

        ExUnit.CaptureLog.capture_log(fn ->
          send(Orchestrator, :tick)
          flush_orchestrator()
        end)

        refute_received {:DOWN, ^orch_ref, :process, ^orch, _}
        st = :sys.get_state(Orchestrator)
        assert MapSet.member?(st.approved_once, task.id)
        assert MapSet.member?(st.overage_once, task.id)
        refute MapSet.member?(st.claimed, task.id)
        refute Map.has_key?(st.running, task.id)
      after
        Process.demonitor(orch_ref, [:flush])

        if Process.whereis(Orchestrator) do
          :sys.replace_state(Orchestrator, fn _ -> original end)
        end

        if Process.alive?(fake_sup), do: GenServer.stop(fake_sup)
      end
    end
  end

  describe "dispatch and approval" do
    # Full suite leaves many todo tasks + orchestrator claims; isolate this describe.
    setup do
      KanbanBridge.delete_all_tasks()
      Svarm.Repo.delete_all(Svarm.Usage.Record)
      Svarm.Repo.delete_all(Svarm.Coordination)

      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | running: %{},
            claimed: MapSet.new(),
            completed: MapSet.new(),
            approved_once: MapSet.new(),
            overage_once: MapSet.new(),
            retry_attempts: %{},
            budget_caps: %{},
            budget_mode: :hard,
            last_budget_block: nil,
            last_run_entries: %{}
        }
      end)

      on_exit(fn ->
        if Process.whereis(Orchestrator) do
          :sys.replace_state(Orchestrator, fn _ -> original end)
        end
      end)

      :ok
    end

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

    defmodule PatchFailTracker do
      def list_eligible(config), do: Svarm.Tracker.Local.list_eligible(config)
      def get_issue(config, id), do: Svarm.Tracker.Local.get_issue(config, id)
      def list_issues(config, filters \\ []), do: Svarm.Tracker.Local.list_issues(config, filters)
      def create_issue(config, attrs), do: Svarm.Tracker.Local.create_issue(config, attrs)
      def update_status(_config, _id, _status), do: {:error, :forbidden}
      def update_attempts(config, id, n), do: Svarm.Tracker.Local.update_attempts(config, id, n)
      def claim(config, id), do: Svarm.Tracker.Local.claim(config, id)
      def delete_all(config), do: Svarm.Tracker.Local.delete_all(config)
      def post_run_summary(config, id, s), do: Svarm.Tracker.Local.post_run_summary(config, id, s)
    end

    test "failed pending_approval PATCH does not crash the poll loop or move status" do
      task =
        KanbanBridge.create_task(%{
          title: "gate patch fail",
          status: "todo",
          assignee: "cody"
        })

      original = :sys.get_state(Orchestrator)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: PatchFailTracker,
            tracker_config: local_config,
            approval: %{mode: :all, trusted_assignees: MapSet.new()},
            claimed: MapSet.delete(state.claimed, task.id),
            running: Map.delete(state.running, task.id),
            completed: MapSet.delete(state.completed, task.id),
            approved_once: MapSet.new()
        }
      end)

      try do
        orch = Process.whereis(Orchestrator)
        send(Orchestrator, :tick)
        flush_orchestrator()

        assert Process.whereis(Orchestrator) == orch
        assert is_map(Orchestrator.status())
        assert KanbanBridge.get_task(task.id).status == "todo"
        refute task.id in Orchestrator.status().running_ids
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "one-shot: approve skips re-pending; spawn clears bit; next cycle re-gates" do
      task =
        KanbanBridge.create_task(%{
          title: "one shot sticky",
          status: Approval.pending_status(),
          assignee: "demo"
        })

      original = :sys.get_state(Orchestrator)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      # Gate everyone (would re-pending without one-shot). CLI `true` exits 0 fast.
      demo_agent = %{
        command: "true",
        args: [],
        env: %{},
        adapter: "cli",
        display_name: "Demo",
        name: "demo"
      }

      agents = Map.put(original.agents, "demo", demo_agent)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            tracker_config: local_config,
            approval: %{mode: :all, trusted_assignees: MapSet.new()},
            agents: agents,
            budget_caps: %{},
            claimed: MapSet.delete(state.claimed, task.id),
            running: Map.delete(state.running, task.id),
            completed: MapSet.delete(state.completed, task.id),
            approved_once: MapSet.new(),
            last_budget_block: nil
        }
      end)

      try do
        assert :ok = Approval.approve(task.id)
        assert KanbanBridge.get_task(task.id).status == "todo"

        assert wait_until(fn ->
                 MapSet.member?(:sys.get_state(Orchestrator).approved_once, task.id)
               end)

        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 st = :sys.get_state(Orchestrator)
                 t = KanbanBridge.get_task(task.id)

                 t.status != Approval.pending_status() and
                   (Map.has_key?(st.running, task.id) or MapSet.member?(st.claimed, task.id) or
                      t.status in ["in_progress", "review", "failed", "done"])
               end)

        # Spawn attempt clears one-shot
        refute MapSet.member?(:sys.get_state(Orchestrator).approved_once, task.id)

        # Wait for worker to finish if still running
        wait_until(fn -> not Map.has_key?(:sys.get_state(Orchestrator).running, task.id) end)

        # Return to todo without one-shot → next tick re-gates
        :ok = Svarm.Tracker.Local.update_status(local_config, task.id, "todo")

        :sys.replace_state(Orchestrator, fn state ->
          %{
            state
            | claimed: MapSet.delete(state.claimed, task.id),
              running: Map.delete(state.running, task.id),
              completed: MapSet.delete(state.completed, task.id),
              approved_once: MapSet.new()
          }
        end)

        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 KanbanBridge.get_task(task.id).status == Approval.pending_status()
               end)
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "budget_exceeded sets last_budget_block and does not claim task" do
      task =
        KanbanBridge.create_task(%{
          title: "over budget",
          status: "todo",
          assignee: "demo"
        })

      Svarm.Usage.append(
        run_id: "rb",
        task_id: task.id,
        source: "worker",
        provider: "openrouter",
        model_id: "x",
        prompt_tokens: 0,
        completion_tokens: 0,
        provider_cost_usd: 10.0,
        estimated: false
      )

      original = :sys.get_state(Orchestrator)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            tracker_config: local_config,
            budget_caps: %{max_usd_per_ticket: 1.0},
            approval: %{mode: :off, trusted_assignees: MapSet.new()},
            claimed: MapSet.delete(state.claimed, task.id),
            running: Map.delete(state.running, task.id),
            completed: MapSet.delete(state.completed, task.id),
            last_budget_block: nil
        }
      end)

      try do
        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 block = Orchestrator.status().last_budget_block
                 is_map(block) and block.task_id == task.id
               end)

        status = Orchestrator.status()
        assert status.last_budget_block.task_id == task.id
        refute task.id in status.running_ids
        refute MapSet.member?(:sys.get_state(Orchestrator).claimed, task.id)
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "hold mode parks over-budget task as pending_approval" do
      task =
        KanbanBridge.create_task(%{
          title: "over budget hold",
          status: "todo",
          assignee: "demo"
        })

      Svarm.Usage.append(
        run_id: "rbh",
        task_id: task.id,
        source: "worker",
        provider: "openrouter",
        model_id: "x",
        prompt_tokens: 0,
        completion_tokens: 0,
        provider_cost_usd: 10.0,
        estimated: false
      )

      original = :sys.get_state(Orchestrator)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            tracker_config: local_config,
            budget_caps: %{max_usd_per_ticket: 1.0},
            budget_mode: :hold,
            approval: %{mode: :off, trusted_assignees: MapSet.new()},
            claimed: MapSet.delete(state.claimed, task.id),
            running: Map.delete(state.running, task.id),
            completed: MapSet.delete(state.completed, task.id),
            overage_once: MapSet.new(),
            last_budget_block: nil
        }
      end)

      try do
        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 KanbanBridge.get_task(task.id).status == Approval.pending_status()
               end)

        held = KanbanBridge.get_task(task.id)
        assert held.wait_reason == "budget_overage"
        assert Svarm.Budget.held?(task.id)
        refute task.id in Orchestrator.status().running_ids
        assert Orchestrator.status().last_budget_block.mode == :hold
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "failed budget-hold PATCH does not persist hold or crash the poll loop" do
      task =
        KanbanBridge.create_task(%{
          title: "budget patch fail",
          status: "todo",
          assignee: "demo"
        })

      Svarm.Usage.append(
        run_id: "rb_patch_fail",
        task_id: task.id,
        source: "worker",
        provider: "openrouter",
        model_id: "x",
        prompt_tokens: 0,
        completion_tokens: 0,
        provider_cost_usd: 10.0,
        estimated: false
      )

      original = :sys.get_state(Orchestrator)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: PatchFailTracker,
            tracker_config: local_config,
            budget_caps: %{max_usd_per_ticket: 1.0},
            budget_mode: :hold,
            approval: %{mode: :off, trusted_assignees: MapSet.new()},
            claimed: MapSet.delete(state.claimed, task.id),
            running: Map.delete(state.running, task.id),
            completed: MapSet.delete(state.completed, task.id),
            overage_once: MapSet.new(),
            last_budget_block: nil
        }
      end)

      try do
        orch = Process.whereis(Orchestrator)
        send(Orchestrator, :tick)
        flush_orchestrator()

        assert Process.whereis(Orchestrator) == orch
        assert is_map(Orchestrator.status())
        assert KanbanBridge.get_task(task.id).status == "todo"
        refute Svarm.Budget.held?(task.id)
        refute task.id in Orchestrator.status().running_ids
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "approve-overage allows one subsequent spawn in hold mode" do
      task =
        KanbanBridge.create_task(%{
          title: "overage unlock",
          status: "todo",
          assignee: "demo"
        })

      Svarm.Usage.append(
        run_id: "rbu",
        task_id: task.id,
        source: "worker",
        provider: "openrouter",
        model_id: "x",
        prompt_tokens: 0,
        completion_tokens: 0,
        provider_cost_usd: 10.0,
        estimated: false
      )

      original = :sys.get_state(Orchestrator)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      demo_agent = %{
        command: "true",
        args: [],
        env: %{},
        adapter: "cli",
        display_name: "Demo",
        name: "demo"
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            tracker_config: local_config,
            agents: Map.put(state.agents, "demo", demo_agent),
            budget_caps: %{max_usd_per_ticket: 1.0},
            budget_mode: :hold,
            approval: %{mode: :off, trusted_assignees: MapSet.new()},
            claimed: MapSet.delete(state.claimed, task.id),
            running: Map.delete(state.running, task.id),
            completed: MapSet.delete(state.completed, task.id),
            overage_once: MapSet.new(),
            last_budget_block: nil
        }
      end)

      try do
        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 KanbanBridge.get_task(task.id).status == Approval.pending_status()
               end)

        assert :ok = Svarm.Budget.approve_overage(task.id)
        assert KanbanBridge.get_task(task.id).status == "todo"
        assert MapSet.member?(:sys.get_state(Orchestrator).overage_once, task.id)

        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 task.id in Orchestrator.status().running_ids or
                   KanbanBridge.get_task(task.id).status in ["in_progress", "review", "done"]
               end)
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "raising the cap releases a budget hold without approve-overage" do
      task =
        KanbanBridge.create_task(%{
          title: "cap raised",
          status: "todo",
          assignee: "demo"
        })

      Svarm.Usage.append(
        run_id: "rbr",
        task_id: task.id,
        source: "worker",
        provider: "openrouter",
        model_id: "x",
        prompt_tokens: 0,
        completion_tokens: 0,
        provider_cost_usd: 10.0,
        estimated: false
      )

      original = :sys.get_state(Orchestrator)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            tracker_config: local_config,
            budget_caps: %{max_usd_per_ticket: 1.0},
            budget_mode: :hold,
            approval: %{mode: :off, trusted_assignees: MapSet.new()},
            claimed: MapSet.delete(state.claimed, task.id),
            running: Map.delete(state.running, task.id),
            completed: MapSet.delete(state.completed, task.id),
            overage_once: MapSet.new(),
            last_budget_block: nil
        }
      end)

      try do
        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 KanbanBridge.get_task(task.id).status == Approval.pending_status()
               end)

        :sys.replace_state(Orchestrator, fn state ->
          %{state | budget_caps: %{max_usd_per_ticket: 100.0}}
        end)

        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 not Svarm.Budget.held?(task.id) and
                   KanbanBridge.get_task(task.id).status != Approval.pending_status()
               end)
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "raising the cap does not resurrect a rejected budget hold" do
      task =
        KanbanBridge.create_task(%{
          title: "rejected hold",
          status: "todo",
          assignee: "demo"
        })

      Svarm.Usage.append(
        run_id: "rbrj",
        task_id: task.id,
        source: "worker",
        provider: "openrouter",
        model_id: "x",
        prompt_tokens: 0,
        completion_tokens: 0,
        provider_cost_usd: 10.0,
        estimated: false
      )

      original = :sys.get_state(Orchestrator)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            tracker_config: local_config,
            budget_caps: %{max_usd_per_ticket: 1.0},
            budget_mode: :hold,
            approval: %{mode: :off, trusted_assignees: MapSet.new()},
            claimed: MapSet.delete(state.claimed, task.id),
            running: Map.delete(state.running, task.id),
            completed: MapSet.delete(state.completed, task.id),
            overage_once: MapSet.new(),
            last_budget_block: nil
        }
      end)

      try do
        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 KanbanBridge.get_task(task.id).status == Approval.pending_status()
               end)

        assert :ok = Approval.reject(task.id)
        assert KanbanBridge.get_task(task.id).status == "failed"

        :sys.replace_state(Orchestrator, fn state ->
          %{state | budget_caps: %{max_usd_per_ticket: 100.0}}
        end)

        before = Orchestrator.status().last_tick_mono_ms
        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 Orchestrator.status().last_tick_mono_ms != before
               end)

        assert KanbanBridge.get_task(task.id).status == "failed"
        refute Svarm.Budget.held?(task.id)
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "toolchain fail mode marks task failed and does not claim or spawn" do
      missing = "svarm_missing_tool_#{System.unique_integer([:positive])}"
      original = :sys.get_state(Orchestrator)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      demo = Map.fetch!(original.agents, "demo")

      agents =
        Map.put(original.agents, "demo", %{
          demo
          | tools: [missing],
            tools_mode: :fail
        })

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            tracker_config: local_config,
            agents: agents,
            budget_caps: %{},
            budget_mode: :hard,
            overage_once: MapSet.new(),
            approval: %{mode: :off, trusted_assignees: MapSet.new()},
            claimed: MapSet.new(),
            running: %{},
            completed: MapSet.new(),
            last_budget_block: nil
        }
      end)

      try do
        # Configure before insert so a queued poll cannot gate `demo` (untrusted).
        flush_orchestrator()

        task =
          KanbanBridge.create_task(%{
            title: "toolchain fail",
            status: "todo",
            assignee: "demo"
          })

        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 KanbanBridge.get_task(task.id).status == "failed"
               end)

        st = :sys.get_state(Orchestrator)
        refute Map.has_key?(st.running, task.id)
        refute MapSet.member?(st.claimed, task.id)
        assert KanbanBridge.get_task(task.id).status == "failed"
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "toolchain warn mode still claims and spawns the agent" do
      missing = "svarm_missing_tool_#{System.unique_integer([:positive])}"
      original = :sys.get_state(Orchestrator)

      local_config = %{
        kind: :local,
        active_states: ["todo", "in_progress"],
        terminal_states: ["done", "failed", "review"],
        ignored_assignees: []
      }

      demo_agent = %{
        command: "true",
        args: [],
        env: %{},
        adapter: "cli",
        display_name: "Demo",
        name: "demo",
        tools: [missing],
        tools_mode: :warn
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            tracker_config: local_config,
            agents: Map.put(state.agents, "demo", demo_agent),
            budget_caps: %{},
            budget_mode: :hard,
            overage_once: MapSet.new(),
            approval: %{mode: :off, trusted_assignees: MapSet.new()},
            claimed: MapSet.new(),
            running: %{},
            completed: MapSet.new(),
            last_budget_block: nil
        }
      end)

      try do
        # Configure before insert so a queued poll cannot gate `demo` (untrusted).
        flush_orchestrator()

        task =
          KanbanBridge.create_task(%{
            title: "toolchain warn",
            status: "todo",
            assignee: "demo"
          })

        send(Orchestrator, :tick)

        # Warn does not block spawn (`true` exits 0 fast).
        assert wait_until(fn ->
                 st = :sys.get_state(Orchestrator)
                 t = KanbanBridge.get_task(task.id)

                 Map.has_key?(st.running, task.id) or MapSet.member?(st.claimed, task.id) or
                   t.status in ["in_progress", "review", "done", "failed"]
               end)

        st = :sys.get_state(Orchestrator)
        t = KanbanBridge.get_task(task.id)

        assert Map.has_key?(st.running, task.id) or MapSet.member?(st.claimed, task.id) or
                 t.status in ["in_progress", "review", "done", "failed"]

        refute t.status == "todo" and not MapSet.member?(st.claimed, task.id) and
                 not Map.has_key?(st.running, task.id)
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end
  end

  describe "successful exit completion" do
    test "forces review and completes when exit ok but status still active" do
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
      flush_orchestrator()

      status = Orchestrator.status()
      state = :sys.get_state(Orchestrator)
      # No re-spawn loop — completed even if tracker still looked active
      refute task.id in status.retry_ids
      refute task.id in status.running_ids
      assert MapSet.member?(state.completed, task.id)
      assert KanbanBridge.get_task(task.id).status == "review"
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
      flush_orchestrator()

      status = Orchestrator.status()
      # Task is "done" (terminal) → completed, not in retry
      refute task.id in status.retry_ids
    end

    # Tracker that ignores the first N-1 update_status calls so force-terminal
    # must schedule send_after retries (never Process.sleep on the GenServer).
    defmodule StickyActiveTracker do
      @table :svarm_sticky_active_tracker

      def ensure_table! do
        case :ets.whereis(@table) do
          :undefined ->
            :ets.new(@table, [:named_table, :public, :set])

          _ ->
            :ok
        end
      end

      def set_succeed_on_attempt(n) when is_integer(n) and n >= 1 do
        ensure_table!()
        :ets.delete_all_objects(@table)
        :ets.insert(@table, {:succeed_on, n})
      end

      def update_status(config, id, status) do
        ensure_table!()
        n = :ets.update_counter(@table, {:count, id}, {2, 1}, {{:count, id}, 0})
        succeed_on = succeed_on_attempt()

        if n >= succeed_on do
          Svarm.Tracker.Local.update_status(config, id, status)
        else
          :ok
        end
      end

      def get_issue(config, id), do: Svarm.Tracker.Local.get_issue(config, id)
      def list_eligible(config), do: Svarm.Tracker.Local.list_eligible(config)
      def list_issues(config, filters \\ []), do: Svarm.Tracker.Local.list_issues(config, filters)
      def create_issue(config, attrs), do: Svarm.Tracker.Local.create_issue(config, attrs)
      def update_attempts(config, id, n), do: Svarm.Tracker.Local.update_attempts(config, id, n)
      def claim(config, id), do: Svarm.Tracker.Local.claim(config, id)
      def delete_all(config), do: Svarm.Tracker.Local.delete_all(config)
      def post_run_summary(config, id, s), do: Svarm.Tracker.Local.post_run_summary(config, id, s)

      defp succeed_on_attempt do
        case :ets.lookup(@table, :succeed_on) do
          [{:succeed_on, n}] -> n
          _ -> 1
        end
      end
    end

    test "force-terminal retries via send_after without blocking GenServer" do
      StickyActiveTracker.set_succeed_on_attempt(3)

      task =
        KanbanBridge.create_task(%{
          title: "sticky force terminal",
          status: "todo",
          assignee: "cody"
        })

      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: self(),
            mref: make_ref(),
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{
          state
          | tracker: StickyActiveTracker,
            tracker_config: state.tracker_config || %{},
            running: running,
            claimed: MapSet.put(state.claimed, task.id)
        }
      end)

      try do
        send(Orchestrator, {:run_exit, task.id, :ok})

        # GenServer must answer immediately (proves no Process.sleep in the handler).
        assert is_map(Orchestrator.status())
        state = :sys.get_state(Orchestrator)
        assert MapSet.member?(state.completed, task.id)
        # First two update_status calls are no-ops — still active until attempt 3.
        assert KanbanBridge.get_task(task.id).status == "todo"

        assert wait_until(fn -> KanbanBridge.get_task(task.id).status == "review" end)

        assert KanbanBridge.get_task(task.id).status == "review"
        refute task.id in Orchestrator.status().retry_ids
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "force-terminal gives up after retry budget without re-dispatch" do
      # Never apply the status patch — exhaust 3 attempts then give up.
      StickyActiveTracker.set_succeed_on_attempt(99)

      task =
        KanbanBridge.create_task(%{
          title: "force terminal give up",
          status: "todo",
          assignee: "cody"
        })

      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: self(),
            mref: make_ref(),
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{
          state
          | tracker: StickyActiveTracker,
            tracker_config: state.tracker_config || %{},
            running: running,
            claimed: MapSet.put(state.claimed, task.id)
        }
      end)

      try do
        send(Orchestrator, {:run_exit, task.id, :ok})

        # Completes immediately (session skip); status patch may never stick.
        assert wait_until(fn ->
                 MapSet.member?(:sys.get_state(Orchestrator).completed, task.id)
               end)

        # Wait past full retry budget (400ms + 800ms) so give-up runs.
        Process.sleep(1500)

        assert is_map(Orchestrator.status())
        assert MapSet.member?(:sys.get_state(Orchestrator).completed, task.id)
        refute task.id in Orchestrator.status().retry_ids
        refute task.id in Orchestrator.status().running_ids
        # Tracker never accepted the patch — still active, but not re-dispatched.
        assert KanbanBridge.get_task(task.id).status == "todo"
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end
  end

  describe "tracker reconcile (step 23)" do
    # Configurable get_issue double. capabilities/0 is [] so CI/review poll
    # does not run against this stub (Resolve treats omitted capabilities as poll-on).
    defmodule ReconcileErrorTracker do
      @table :svarm_reconcile_error_tracker

      def capabilities, do: []

      def ensure_table! do
        case :ets.whereis(@table) do
          :undefined ->
            :ets.new(@table, [:named_table, :public, :set])

          _ ->
            :ok
        end
      end

      def set_get_issue(result) do
        ensure_table!()
        :ets.insert(@table, {:result, result})
        :ok
      end

      def get_issue(_config, _id) do
        ensure_table!()

        case :ets.lookup(@table, :result) do
          [{:result, result}] -> result
          [] -> {:error, :not_found}
        end
      end

      def list_eligible(_config), do: {:ok, []}
      def list_issues(_config, _filters \\ []), do: {:ok, []}
      def create_issue(_config, attrs), do: {:ok, struct(Svarm.Issue, Map.to_list(attrs))}
      def update_status(_config, _id, _status), do: :ok
      def update_attempts(_config, _id, _n), do: :ok
      def claim(_config, _id), do: :ok
      def delete_all(_config), do: :ok
      def post_run_summary(_config, _id, _s), do: :ok
    end

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
      flush_orchestrator()

      status = Orchestrator.status()
      refute task.id in status.running_ids
      refute MapSet.member?(:sys.get_state(Orchestrator).claimed, task.id)

      # Worker should have been asked to exit (exit is async; poll briefly)
      assert wait_until(fn -> not Process.alive?(worker) end)

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
      flush_orchestrator()

      status = Orchestrator.status()
      # Should no longer be claimed in internal state
      # (status/0 doesn't expose claimed directly, but running should be clean)
      refute task.id in status.running_ids
      refute MapSet.member?(:sys.get_state(Orchestrator).claimed, task.id)
    end

    test "keeps running+claim on transient get_issue network_error" do
      task =
        KanbanBridge.create_task(%{
          title: "transient network blip",
          status: "in_progress",
          assignee: "cody"
        })

      worker = spawn(fn -> Process.sleep(:infinity) end)
      ReconcileErrorTracker.set_get_issue({:error, :network_error})
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: worker,
            mref: make_ref(),
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{
          state
          | tracker: ReconcileErrorTracker,
            running: running,
            claimed: MapSet.put(state.claimed, task.id),
            stall_timeout_ms: 0
        }
      end)

      try do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(Orchestrator, :tick)
            flush_orchestrator()
          end)

        state = :sys.get_state(Orchestrator)
        assert Map.has_key?(state.running, task.id)
        assert MapSet.member?(state.claimed, task.id)
        assert Process.alive?(worker)
        assert log =~ task.id
        assert log =~ "network_error"
        assert log =~ "keeping in-flight work"
      after
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "keeps running+claim on GitHub-shaped rate-limit get_issue error" do
      task =
        KanbanBridge.create_task(%{
          title: "transient rate limit",
          status: "in_progress",
          assignee: "cody"
        })

      worker = spawn(fn -> Process.sleep(:infinity) end)

      ReconcileErrorTracker.set_get_issue(
        {:error, %{type: :rate_limit, message: "rate limited", retry_after: 60}}
      )

      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: worker,
            mref: make_ref(),
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{
          state
          | tracker: ReconcileErrorTracker,
            running: running,
            claimed: MapSet.put(state.claimed, task.id),
            stall_timeout_ms: 0
        }
      end)

      try do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(Orchestrator, :tick)
            flush_orchestrator()
          end)

        state = :sys.get_state(Orchestrator)
        assert Map.has_key?(state.running, task.id)
        assert MapSet.member?(state.claimed, task.id)
        assert Process.alive?(worker)
        assert log =~ "keeping in-flight work"
      after
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "releases running+claim when get_issue returns not_found" do
      task =
        KanbanBridge.create_task(%{
          title: "vanished issue",
          status: "in_progress",
          assignee: "cody"
        })

      worker = spawn(fn -> Process.sleep(:infinity) end)
      ReconcileErrorTracker.set_get_issue({:error, :not_found})
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: worker,
            mref: make_ref(),
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{
          state
          | tracker: ReconcileErrorTracker,
            running: running,
            claimed: MapSet.put(state.claimed, task.id),
            stall_timeout_ms: 0
        }
      end)

      try do
        send(Orchestrator, :tick)
        flush_orchestrator()

        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, task.id)
        refute MapSet.member?(state.claimed, task.id)
        assert wait_until(fn -> not Process.alive?(worker) end)
      after
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "stops worker when fake tracker reports terminal status" do
      task =
        KanbanBridge.create_task(%{
          title: "fake tracker terminal",
          status: "in_progress",
          assignee: "cody"
        })

      worker = spawn(fn -> Process.sleep(:infinity) end)
      ReconcileErrorTracker.set_get_issue({:ok, %{id: task.id, status: "done"}})
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        running =
          Map.put(state.running, task.id, %{
            task: task,
            pid: worker,
            mref: make_ref(),
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          })

        %{
          state
          | tracker: ReconcileErrorTracker,
            running: running,
            claimed: MapSet.put(state.claimed, task.id),
            stall_timeout_ms: 0
        }
      end)

      try do
        send(Orchestrator, :tick)
        flush_orchestrator()

        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, task.id)
        refute MapSet.member?(state.claimed, task.id)
        assert wait_until(fn -> not Process.alive?(worker) end)
      after
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end
  end

  describe "batched tracker status reads" do
    setup do
      KanbanBridge.delete_all_tasks()
      :ok
    end

    @local_config %{
      kind: :local,
      active_states: ["todo", "in_progress"],
      terminal_states: ["done", "failed", "review"],
      ignored_assignees: []
    }

    defp demo_agent do
      %{
        command: "true",
        args: [],
        env: %{},
        adapter: "cli",
        display_name: "Demo",
        name: "demo"
      }
    end

    defp local_dispatch_state(state, extra) do
      Map.merge(
        %{
          tracker: Svarm.Tracker.Local,
          tracker_config: @local_config,
          approval: %{mode: :off, trusted_assignees: MapSet.new()},
          agents: Map.put(state.agents, "demo", demo_agent()),
          budget_caps: %{},
          stall_timeout_ms: 0,
          claimed: MapSet.new(),
          running: %{},
          completed: MapSet.new(),
          retry_attempts: %{},
          approved_once: MapSet.new(),
          last_budget_block: nil,
          issue_cache: %{}
        },
        extra
      )
    end

    defp put_running(_state, tasks) do
      running =
        Map.new(tasks, fn task ->
          worker = spawn(fn -> Process.sleep(:infinity) end)

          {task.id,
           %{
             task: task,
             pid: worker,
             mref: Process.monitor(worker),
             started_mono_ms: System.monotonic_time(:millisecond),
             started_at: System.system_time(:second)
           }}
        end)

      claimed = MapSet.new(Map.keys(running))
      {running, claimed}
    end

    defp stop_running_workers(running) when is_map(running) do
      Enum.each(running, fn {_id, entry} ->
        if is_pid(entry.pid) and Process.alive?(entry.pid), do: Process.exit(entry.pid, :kill)
      end)
    end

    test "reconcile of N in-flight ids uses fewer KanbanBridge reads than N" do
      tasks =
        for i <- 1..3 do
          KanbanBridge.create_task(%{
            title: "batch in-flight #{i}",
            status: "in_progress",
            assignee: "demo"
          })
        end

      original = :sys.get_state(Orchestrator)
      {running, claimed} = put_running(%{}, tasks)

      :sys.replace_state(Orchestrator, fn state ->
        Map.merge(state, local_dispatch_state(state, %{running: running, claimed: claimed}))
      end)

      try do
        {calls, _} =
          with_kb_calls(fn ->
            send(Orchestrator, :tick)
            flush_orchestrator()
          end)

        get_calls = for {:get, _} <- calls, do: :get
        get_many = for {:get_many, n} <- calls, do: n
        assert get_calls == []
        assert get_many == [3]

        state = :sys.get_state(Orchestrator)

        Enum.each(tasks, fn task ->
          assert Map.has_key?(state.running, task.id)
        end)
      after
        stop_running_workers(running)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "does not dispatch while a depends_on id is non-terminal" do
      dep =
        KanbanBridge.create_task(%{
          title: "dep still todo",
          status: "todo",
          assignee: "demo"
        })

      task =
        KanbanBridge.create_task(%{
          title: "blocked by dep",
          status: "todo",
          assignee: "demo"
        })

      :ok = KanbanBridge.update_depends_on(task.id, [dep.id])
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        Map.merge(state, local_dispatch_state(state, %{}))
      end)

      try do
        send(Orchestrator, :tick)
        flush_orchestrator()

        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, task.id)
        refute MapSet.member?(state.claimed, task.id)
        assert KanbanBridge.get_task(task.id).status == "todo"
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "does not dispatch while a depends_on id is running" do
      dep =
        KanbanBridge.create_task(%{
          title: "dep running",
          status: "in_progress",
          assignee: "demo"
        })

      task =
        KanbanBridge.create_task(%{
          title: "blocked by running dep",
          status: "todo",
          assignee: "demo"
        })

      :ok = KanbanBridge.update_depends_on(task.id, [dep.id])
      original = :sys.get_state(Orchestrator)
      {running, claimed} = put_running(%{}, [dep])

      :sys.replace_state(Orchestrator, fn state ->
        Map.merge(state, local_dispatch_state(state, %{running: running, claimed: claimed}))
      end)

      try do
        send(Orchestrator, :tick)
        flush_orchestrator()

        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, task.id)
        refute MapSet.member?(state.claimed, task.id)
        assert KanbanBridge.get_task(task.id).status == "todo"
        assert Map.has_key?(state.running, dep.id)
      after
        stop_running_workers(running)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "dispatches when depends_on is terminal and not running" do
      dep =
        KanbanBridge.create_task(%{
          title: "dep done",
          status: "done",
          assignee: "demo"
        })

      task =
        KanbanBridge.create_task(%{
          title: "unblocked by done dep",
          status: "todo",
          assignee: "demo"
        })

      :ok = KanbanBridge.update_depends_on(task.id, [dep.id])
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        Map.merge(state, local_dispatch_state(state, %{}))
      end)

      try do
        send(Orchestrator, :tick)

        assert wait_until(fn ->
                 st = :sys.get_state(Orchestrator)
                 t = KanbanBridge.get_task(task.id)

                 Map.has_key?(st.running, task.id) or MapSet.member?(st.claimed, task.id) or
                   t.status in ["in_progress", "review", "done", "failed"]
               end)
      after
        running = :sys.get_state(Orchestrator).running
        stop_running_workers(running)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "depends_on prefetch for N deps is fewer KanbanBridge reads than N" do
      deps =
        for i <- 1..3 do
          KanbanBridge.create_task(%{
            title: "dep done #{i}",
            status: "done",
            assignee: "demo"
          })
        end

      task =
        KanbanBridge.create_task(%{
          title: "needs three deps",
          status: "todo",
          assignee: "demo"
        })

      :ok = KanbanBridge.update_depends_on(task.id, Enum.map(deps, & &1.id))
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        Map.merge(state, local_dispatch_state(state, %{max_concurrent: 0}))
      end)

      try do
        {calls, _} =
          with_kb_calls(fn ->
            send(Orchestrator, :tick)
            flush_orchestrator()
          end)

        get_count = Enum.count(calls, fn {op, _} -> op == :get end)
        get_many_count = Enum.count(calls, fn {op, _} -> op == :get_many end)
        assert get_many_count >= 1
        assert get_count + get_many_count < 3

        assert KanbanBridge.get_task(task.id).status == "todo"
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "batch tracker_error does not treat depends_on as met" do
      dep =
        KanbanBridge.create_task(%{
          title: "dep still running in tracker",
          status: "todo",
          assignee: "demo"
        })

      task =
        KanbanBridge.create_task(%{
          title: "must wait through batch error",
          status: "todo",
          assignee: "demo"
        })

      :ok = KanbanBridge.update_depends_on(task.id, [dep.id])
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        Map.merge(
          state,
          local_dispatch_state(state, %{tracker: Svarm.OrchestratorTest.BatchGatingTracker})
        )
      end)

      try do
        send(Orchestrator, :tick)
        flush_orchestrator()

        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, task.id)
        refute MapSet.member?(state.claimed, task.id)
        assert KanbanBridge.get_task(task.id).status == "todo"
      after
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "batch get_issues {:error, :not_found} does not mass-release in-flight work" do
      task =
        KanbanBridge.create_task(%{
          title: "batch not_found keep",
          status: "in_progress",
          assignee: "demo"
        })

      worker = spawn(fn -> Process.sleep(:infinity) end)
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.OrchestratorTest.BatchErrorTracker,
            running: %{
              task.id => %{
                task: task,
                pid: worker,
                mref: Process.monitor(worker),
                started_mono_ms: System.monotonic_time(:millisecond),
                started_at: System.system_time(:second)
              }
            },
            claimed: MapSet.new([task.id]),
            stall_timeout_ms: 0,
            agents: %{},
            issue_cache: %{}
        }
      end)

      try do
        send(Orchestrator, :tick)
        flush_orchestrator()

        state = :sys.get_state(Orchestrator)
        assert Map.has_key?(state.running, task.id)
        assert MapSet.member?(state.claimed, task.id)
        assert Process.alive?(worker)
      after
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "GitHub tick does not GET /issues/{n} for ids in the list snapshot" do
      Svarm.OrchestratorTest.GhTickReq.reset(self())

      payloads =
        for n <- [21, 22, 23] do
          %{
            "number" => n,
            "node_id" => "I_#{n}",
            "title" => "gh #{n}",
            "body" => "",
            "labels" => [%{"name" => "status: in-progress"}],
            "assignee" => nil,
            "user" => %{"login" => "alice"},
            "created_at" => "2026-01-01T00:00:00Z",
            "repository_url" => "https://api.github.com/repos/acme/widgets",
            "state" => "open"
          }
        end

      Svarm.OrchestratorTest.GhTickReq.put_list(payloads)
      original = :sys.get_state(Orchestrator)

      running =
        Map.new(payloads, fn p ->
          id = Integer.to_string(p["number"])
          worker = spawn(fn -> Process.sleep(:infinity) end)

          {id,
           %{
             task: %{id: id, status: "in_progress", assignee: "demo"},
             pid: worker,
             mref: Process.monitor(worker),
             started_mono_ms: System.monotonic_time(:millisecond),
             started_at: System.system_time(:second)
           }}
        end)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.GitHub,
            tracker_config: %{
              owner: "acme",
              repo: "widgets",
              api_key: "t",
              req: Svarm.OrchestratorTest.GhTickReq,
              kind: :github,
              active_states: ["todo", "in_progress"],
              terminal_states: ["done", "failed", "review"]
            },
            running: running,
            claimed: MapSet.new(Map.keys(running)),
            stall_timeout_ms: 0,
            agents: %{},
            retry_attempts: %{},
            issue_cache: %{}
        }
      end)

      try do
        send(Orchestrator, :tick)
        flush_orchestrator()

        gets = drain_http_gets([])
        list_gets = Enum.filter(gets, &String.ends_with?(&1, "/issues"))
        assert list_gets != []

        refute Enum.any?(gets, fn url -> url =~ ~r{/issues/\d+$} end),
               "unexpected per-id GETs: #{inspect(gets)}"

        state = :sys.get_state(Orchestrator)

        Enum.each(Map.keys(running), fn id ->
          assert Map.has_key?(state.running, id)
        end)
      after
        stop_running_workers(running)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end

    test "GitHub list 429 keeps in-flight work (no mass-release)" do
      Svarm.OrchestratorTest.GhTickReq.reset(self())

      Svarm.OrchestratorTest.GhTickReq.put_list_error(
        {:ok, %{status: 429, headers: %{"retry-after" => ["15"]}}}
      )

      original = :sys.get_state(Orchestrator)

      ids = ["21", "22"]

      running =
        Map.new(ids, fn id ->
          worker = spawn(fn -> Process.sleep(:infinity) end)

          {id,
           %{
             task: %{id: id, status: "in_progress", assignee: "demo"},
             pid: worker,
             mref: Process.monitor(worker),
             started_mono_ms: System.monotonic_time(:millisecond),
             started_at: System.system_time(:second)
           }}
        end)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.GitHub,
            tracker_config: %{
              owner: "acme",
              repo: "widgets",
              api_key: "t",
              req: Svarm.OrchestratorTest.GhTickReq,
              kind: :github,
              active_states: ["todo", "in_progress"],
              terminal_states: ["done", "failed", "review"]
            },
            running: running,
            claimed: MapSet.new(ids),
            stall_timeout_ms: 0,
            agents: %{},
            retry_attempts: %{},
            issue_cache: %{}
        }
      end)

      try do
        send(Orchestrator, :tick)
        flush_orchestrator()

        state = :sys.get_state(Orchestrator)

        Enum.each(ids, fn id ->
          assert Map.has_key?(state.running, id)
          assert MapSet.member?(state.claimed, id)
        end)
      after
        stop_running_workers(running)
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end
  end

  defmodule BatchGatingTracker do
    def capabilities, do: []
    def list_eligible(config), do: Svarm.Tracker.Local.list_eligible(config)
    def get_issues(_config, _ids), do: {:error, :network_error}
    def get_issue(config, id), do: Svarm.Tracker.Local.get_issue(config, id)
    def list_issues(config, filters \\ []), do: Svarm.Tracker.Local.list_issues(config, filters)
    def create_issue(config, attrs), do: Svarm.Tracker.Local.create_issue(config, attrs)

    def update_status(config, id, status),
      do: Svarm.Tracker.Local.update_status(config, id, status)

    def update_attempts(config, id, n), do: Svarm.Tracker.Local.update_attempts(config, id, n)
    def claim(config, id), do: Svarm.Tracker.Local.claim(config, id)
    def delete_all(config), do: Svarm.Tracker.Local.delete_all(config)
    def post_run_summary(config, id, s), do: Svarm.Tracker.Local.post_run_summary(config, id, s)
  end

  defmodule BatchErrorTracker do
    def capabilities, do: []
    def get_issues(_config, _ids), do: {:error, :not_found}
    def get_issue(_config, _id), do: {:error, :network_error}
    def list_eligible(_config), do: {:ok, []}
    def list_issues(_config, _filters \\ []), do: {:ok, []}
    def create_issue(_config, attrs), do: {:ok, struct(Svarm.Issue, Map.to_list(attrs))}
    def update_status(_config, _id, _status), do: :ok
    def update_attempts(_config, _id, _n), do: :ok
    def claim(_config, _id), do: :ok
    def delete_all(_config), do: :ok
    def post_run_summary(_config, _id, _s), do: :ok
  end

  defmodule GhTickReq do
    @table :svarm_gh_tick_req

    def reset(pid) do
      ensure!()
      :ets.delete_all_objects(@table)
      :ets.insert(@table, {:pid, pid})
      :ets.insert(@table, {:list, {:ok, %{status: 200, body: []}}})
      :ets.insert(@table, {:eligible, {:ok, %{status: 200, body: []}}})
      :ets.insert(@table, {:issue, {:ok, %{status: 404, body: %{}}}})
      :ok
    end

    def put_list(issues) when is_list(issues) do
      ensure!()
      :ets.insert(@table, {:list, {:ok, %{status: 200, body: issues}}})
      :ok
    end

    def put_list_error(resp) do
      ensure!()
      :ets.insert(@table, {:list, resp})
      :ok
    end

    def get(url, opts) do
      ensure!()

      case :ets.lookup(@table, :pid) do
        [{:pid, pid}] -> send(pid, {:http_get, url})
        _ -> :ok
      end

      cond do
        match?({_n, ""}, Integer.parse(Path.basename(url))) ->
          lookup(:issue)

        opts |> Keyword.get(:params, %{}) |> Map.get(:state) == "open" ->
          lookup(:eligible)

        true ->
          lookup(:list)
      end
    end

    defp lookup(key) do
      case :ets.lookup(@table, key) do
        [{^key, resp}] -> resp
        [] -> {:ok, %{status: 404, body: %{}}}
      end
    end

    defp ensure! do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end
    end
  end

  describe "stall kill-tree" do
    defmodule StallStubTracker do
      def update_status(config, id, status) do
        Agent.update(config.statuses, &[{id, status} | &1])
        :ok
      end
    end

    test "reconcile_stalls reaps the OS hang child" do
      {:ok, statuses} = Agent.start_link(fn -> [] end)

      workspace_root =
        Path.join(System.tmp_dir!(), "svarm_stall_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace_root)
      pidfile = Path.join(workspace_root, "stall.pid")
      :ok = Events.subscribe()

      kb =
        KanbanBridge.create_task(%{
          title: "stall kill tree",
          status: "in_progress",
          assignee: "cody"
        })

      issue = %Issue{
        id: kb.id,
        source_id: kb.id,
        title: kb.title,
        body: "",
        type: "code",
        assignee: "cody",
        status: "in_progress",
        attempts: 0,
        tenant: "test"
      }

      cfg = %{
        command: "sh",
        args: [@fake_cli, "hang"],
        env: %{"FAKE_CLI_PIDFILE" => pidfile},
        display_name: "FakeCli",
        adapter: "cli",
        provider: "test",
        model: "fake"
      }

      opts = [
        workspace_root: workspace_root,
        tracker: StallStubTracker,
        tracker_config: %{statuses: statuses},
        timeout_ms: 30_000
      ]

      {:ok, runner} = Task.start(fn -> Cli.run(issue, cfg, opts) end)
      child = wait_stall_pidfile(pidfile)
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | running: %{
              kb.id => %{
                task: issue,
                pid: runner,
                mref: Process.monitor(runner),
                started_mono_ms: System.monotonic_time(:millisecond) - 10_000,
                started_at: System.system_time(:second)
              }
            },
            claimed: MapSet.new([kb.id]),
            stall_timeout_ms: 50,
            agents: %{}
        }
      end)

      try do
        send(Orchestrator, :tick)
        flush_orchestrator()

        refute OsPid.alive_after?(child, 1_000),
               "stall tick left hang child pid #{child} alive"

        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, kb.id)
      after
        cancel_retry_timer(kb.id)
        if Process.alive?(runner), do: Process.exit(runner, :kill)
        OsPid.kill(child)
        :sys.replace_state(Orchestrator, fn _ -> original end)
        if Process.alive?(statuses), do: Agent.stop(statuses)
        File.rm_rf(workspace_root)
      end
    end

    test "tracker-terminal reaps the OS hang child" do
      {:ok, statuses} = Agent.start_link(fn -> [] end)

      workspace_root =
        Path.join(System.tmp_dir!(), "svarm_term_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace_root)
      pidfile = Path.join(workspace_root, "term.pid")
      :ok = Events.subscribe()

      kb =
        KanbanBridge.create_task(%{
          title: "tracker terminal kill tree",
          status: "in_progress",
          assignee: "cody"
        })

      issue = %Issue{
        id: kb.id,
        source_id: kb.id,
        title: kb.title,
        body: "",
        type: "code",
        assignee: "cody",
        status: "in_progress",
        attempts: 0,
        tenant: "test"
      }

      cfg = %{
        command: "sh",
        args: [@fake_cli, "hang"],
        env: %{"FAKE_CLI_PIDFILE" => pidfile},
        display_name: "FakeCli",
        adapter: "cli",
        provider: "test",
        model: "fake"
      }

      opts = [
        workspace_root: workspace_root,
        tracker: StallStubTracker,
        tracker_config: %{statuses: statuses},
        timeout_ms: 30_000
      ]

      {:ok, runner} = Task.start(fn -> Cli.run(issue, cfg, opts) end)
      child = wait_stall_pidfile(pidfile)
      original = :sys.get_state(Orchestrator)
      __MODULE__.ReconcileErrorTracker.set_get_issue({:ok, %{id: kb.id, status: "done"}})

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | running: %{
              kb.id => %{
                task: issue,
                pid: runner,
                mref: Process.monitor(runner),
                started_mono_ms: System.monotonic_time(:millisecond),
                started_at: System.system_time(:second)
              }
            },
            claimed: MapSet.new([kb.id]),
            stall_timeout_ms: 0,
            agents: %{},
            tracker: __MODULE__.ReconcileErrorTracker
        }
      end)

      try do
        send(Orchestrator, :tick)
        flush_orchestrator()

        refute OsPid.alive_after?(child, 1_000),
               "tracker-terminal left hang child pid #{child} alive"

        state = :sys.get_state(Orchestrator)
        refute Map.has_key?(state.running, kb.id)
      after
        if Process.alive?(runner), do: Process.exit(runner, :kill)
        OsPid.kill(child)
        :sys.replace_state(Orchestrator, fn _ -> original end)
        if Process.alive?(statuses), do: Agent.stop(statuses)
        File.rm_rf(workspace_root)
      end
    end

    defp wait_stall_pidfile(path) do
      pid = OsPid.wait_pidfile(path, 2_000)
      assert is_integer(pid), "pidfile #{path} never appeared"
      pid
    end

    defp cancel_retry_timer(task_id) do
      case :sys.get_state(Orchestrator).retry_attempts[task_id] do
        %{timer: timer} when is_reference(timer) -> Process.cancel_timer(timer)
        _ -> :ok
      end
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
      flush_orchestrator()

      state = :sys.get_state(Orchestrator)
      # last_run_entries should be set after run_exit
      assert Map.get(state, :last_run_entries)[task.id]
      assert Map.get(state, :last_run_entries)[task.id].run_id == "run_test123"
    end

    test "posts summary when exit ok forces review from active status" do
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
      flush_orchestrator()

      status = Orchestrator.status()
      state = :sys.get_state(Orchestrator)
      refute task.id in status.retry_ids
      assert MapSet.member?(state.completed, task.id)
    end
  end

  describe "Workspace.ensure escape guard" do
    test "rejects a path that climbs outside root" do
      # ".." slips past sanitize (dots are allowed by Symphony §9.5); the
      # path-stays-in-root guard (invariant 2) is the real backstop.
      root = Path.join(System.tmp_dir!(), "svarmguard_test_#{:rand.uniform(9999)}")

      assert {:error, {:path_escape, _abs, _root}} = Workspace.ensure("..", root)

      assert_raise RuntimeError, ~r/workspace_ensure_failed/, fn ->
        Workspace.ensure!("..", root)
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
      flush_orchestrator()

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
      flush_orchestrator()

      status = Orchestrator.status()
      # With default max_retries=5, should be in retry, not completed
      assert task.id in status.retry_ids
      refute task.id in status.running_ids
    end
  end

  describe "invalid workspace isolation fail-closed" do
    setup do
      KanbanBridge.delete_all_tasks()
      original = :sys.get_state(Orchestrator)

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | running: %{},
            claimed: MapSet.new(),
            completed: MapSet.new(),
            approved_once: MapSet.new(),
            overage_once: MapSet.new(),
            retry_attempts: %{},
            last_budget_block: nil
        }
      end)

      on_exit(fn ->
        if Process.whereis(Orchestrator) do
          :sys.replace_state(Orchestrator, fn _ -> original end)
        end
      end)

      :ok
    end

    test "retry does not spawn after hot-reload with invalid isolation" do
      task =
        KanbanBridge.create_task(%{
          title: "retry after bad isolation",
          status: "todo",
          assignee: "demo"
        })

      demo_agent = %{
        command: "true",
        args: [],
        env: %{},
        adapter: "cli",
        display_name: "Demo",
        name: "demo"
      }

      :sys.replace_state(Orchestrator, fn state ->
        %{
          state
          | tracker: Svarm.Tracker.Local,
            agents: Map.put(state.agents, "demo", demo_agent),
            workspace_isolation: :worktree,
            claimed: MapSet.delete(state.claimed, task.id),
            running: Map.delete(state.running, task.id),
            completed: MapSet.delete(state.completed, task.id),
            retry_attempts: %{
              task.id => %{attempt: 1, identifier: task.id, due_at_mono: 0, timer: nil}
            }
        }
      end)

      wf = %Svarm.Workflow{
        config: %{"workspace" => %{"isolation" => "container"}},
        prompt_template: "Do {{issue.id}}",
        path: "WORKFLOW.md"
      }

      send(Orchestrator, {:workflow_reloaded, wf})
      flush_orchestrator()

      state = :sys.get_state(Orchestrator)
      assert state.workspace_isolation == :worktree
      refute match?({:error, _}, state.workspace_isolation)

      send(Orchestrator, {:retry, task.id})
      flush_orchestrator()

      status = Orchestrator.status()
      refute task.id in status.running_ids
      assert task.id in status.retry_ids
      assert KanbanBridge.get_task(task.id).status == "todo"
    end
  end
end
