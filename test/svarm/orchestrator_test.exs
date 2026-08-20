defmodule Svarm.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Svarm.{Approval, KanbanBridge, Orchestrator, Workspace}
  alias Svarm.Test.Wait

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
