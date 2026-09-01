defmodule Svarm.Orchestrator.Dispatch do
  @moduledoc """
  Eligible-task dispatch, approval/budget/toolchain gates, and worker spawn.

  Eligibility is two-layer: the tracker adapter filters first, then this
  module applies cross-cutting in-flight / terminal / pending-approval /
  depends_on rules and the spawn gates. Runners start under the configured
  Task.Supervisor and report back with `{:run_exit, task_id, result}`.
  """

  require Logger

  alias Svarm.{
    AgentRunner,
    Approval,
    Budget,
    Coordination,
    Events,
    Toolchain
  }

  alias Svarm.Orchestrator.{Issues, Status}

  @doc false
  def valid_preflight?(%{agents: agents, workflow: nil}), do: map_size(agents) > 0
  def valid_preflight?(%{agents: agents}) when map_size(agents) == 0, do: false

  def valid_preflight?(%{workflow: wf}) do
    Svarm.Workflow.Config.validate_workflow(wf) == :ok
  end

  @doc false
  def slots_available?(%{running: running, max_concurrent: mc}), do: map_size(running) < mc

  @doc false
  def run(state) do
    state = maybe_release_budget_holds(state)

    case state.tracker.list_eligible(state.tracker_config) do
      {:ok, candidates} ->
        dep_ids =
          candidates
          |> Enum.flat_map(fn task -> List.wrap(Map.get(task, :depends_on) || []) end)
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        state = Issues.prefetch(state, dep_ids)
        Enum.reduce_while(candidates, state, &dispatch_candidate/2)

      {:error, reason} ->
        Logger.warning("list_eligible failed: #{inspect(reason)}")
        state
    end
  end

  defp dispatch_candidate(task, acc) do
    if slots_full?(acc), do: {:halt, acc}, else: process_candidate(acc, task)
  end

  defp slots_full?(%{running: running, max_concurrent: mc}), do: map_size(running) >= mc

  # Eligibility is checked in two layers:
  # 1. Adapter level (Eligibility.eligible?): tracker-specific rules
  #    (e.g., GitHub: required labels, exclude PRs, blocked status)
  # 2. Orchestrator level (process_candidate): cross-cutting rules
  #    (running/claimed, terminal states, pending approval)
  # This ensures the orchestrator never dispatches an issue that's already
  # in flight, even if the adapter missed it.
  defp process_candidate(acc, task) do
    cond do
      Map.has_key?(acc.running, task.id) or
        MapSet.member?(acc.claimed, task.id) or
        Map.has_key?(acc.retry_attempts, task.id) or
          MapSet.member?(acc.completed, task.id) ->
        {:cont, acc}

      task.status in acc.terminal_states ->
        {:cont, acc}

      task.status == Approval.pending_status() ->
        {:cont, acc}

      not dependencies_met?(task, acc) ->
        {:cont, acc}

      true ->
        {:cont, maybe_gate_or_spawn(acc, task)}
    end
  end

  defp dependencies_met?(%{depends_on: deps}, _acc) when deps in [nil, []], do: true

  defp dependencies_met?(task, acc) do
    Enum.all?(task.depends_on || [], &dependency_met?(&1, acc))
  end

  defp dependency_met?(dep_id, acc) do
    case acc.running[dep_id] do
      nil ->
        case Issues.lookup(acc, dep_id) do
          {:ok, dep} -> dep.status in acc.terminal_states
          # Batch/transient tracker errors must not look like "dep is gone".
          # Missing issues still fail-open (`_ -> true`) as before.
          {:error, {:tracker_error, _}} -> false
          _ -> true
        end

      _ ->
        false
    end
  end

  defp maybe_gate_or_spawn(state, task) do
    cond do
      budget_held_without_permit?(state, task.id) ->
        state

      not MapSet.member?(state.approved_once, task.id) and
          Approval.required?(state.approval, task, state.agents) ->
        hold_for_approval(state, task)

      true ->
        maybe_budget_or_spawn(state, task)
    end
  end

  defp hold_for_approval(state, task) do
    case state.tracker.update_status(state.tracker_config, task.id, Approval.pending_status()) do
      :ok ->
        Logger.info("task #{task.id} held for human approval")
        state

      {:error, reason} ->
        Logger.warning(
          "orchestrator: pending_approval status failed for #{task.id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp hold_for_budget_overage(state, task) do
    case state.tracker.update_status(state.tracker_config, task.id, Approval.pending_status()) do
      :ok ->
        :ok = Budget.persist_hold(task.id)
        Logger.info("task #{task.id} held for budget overage approval")
        state

      {:error, reason} ->
        Logger.warning(
          "orchestrator: budget hold status failed for #{task.id}: #{inspect(reason)}"
        )

        state
    end
  end

  @doc false
  def maybe_budget_or_spawn(state, task) do
    if MapSet.member?(state.overage_once || MapSet.new(), task.id) do
      maybe_toolchain_or_spawn(state, task)
    else
      case Budget.check(task.id, state.budget_caps || %{}) do
        :ok ->
          maybe_toolchain_or_spawn(state, task)

        {:error, :budget_exceeded, meta} ->
          handle_budget_exceeded(state, task, meta)
      end
    end
  end

  defp handle_budget_exceeded(state, task, meta) do
    Logger.warning(
      "budget_exceeded task=#{task.id} mode=#{state.budget_mode} scope=#{meta.scope} spent=#{meta.spent} cap=#{meta.cap}"
    )

    block =
      Map.merge(meta, %{
        task_id: task.id,
        at: System.system_time(:second),
        mode: state.budget_mode || :hard
      })

    state = %{state | last_budget_block: block}

    state =
      if state.budget_mode == :hold do
        hold_for_budget_overage(state, task)
      else
        state
      end

    Status.broadcast(state)
    state
  end

  defp maybe_release_budget_holds(state) do
    Budget.wait_reason()
    |> Coordination.list_by_wait_reason()
    |> Enum.reduce(state, &maybe_release_budget_hold(&2, &1))
  end

  defp maybe_release_budget_hold(state, %{task_id: task_id}) do
    case state.tracker.get_issue(state.tracker_config, task_id) do
      {:ok, task} ->
        if task.status in (state.terminal_states || []) do
          Budget.clear_hold(task_id)
          state
        else
          release_active_budget_hold(state, task)
        end

      _ ->
        state
    end
  end

  defp release_active_budget_hold(state, %{id: task_id} = task) do
    case Budget.check(task_id, state.budget_caps || %{}) do
      :ok ->
        Budget.clear_hold(task_id)

        if task.status == Approval.pending_status() do
          state.tracker.update_status(state.tracker_config, task_id, "todo")
        end

        Logger.info("task #{task_id} released from budget hold (cap now allows spawn)")
        state

      {:error, :budget_exceeded, _} ->
        state
    end
  end

  defp budget_held_without_permit?(state, task_id) do
    Budget.held?(task_id) and not MapSet.member?(state.overage_once || MapSet.new(), task_id)
  end

  # PATH-only host-tool contract (agents.toml `tools` / `tools_mode`).
  # Fail: mark failed + board line, never spawn (no Port / model spend).
  # Warn: board/log note then continue to spawn.
  defp maybe_toolchain_or_spawn(state, task) do
    agent_config = AgentRunner.resolve!(task.assignee, state.agents)

    case Toolchain.check(agent_config) do
      :ok ->
        spawn_worker(state, task)

      {:warn, _missing, msg} ->
        Logger.warning("toolchain_warn task=#{task.id} #{msg}")
        Events.broadcast_agent_line(task.id, "\n[toolchain: #{msg}]\n")
        spawn_worker(state, task)

      {:error, :toolchain_missing, _missing, msg} ->
        Logger.error("toolchain_missing task=#{task.id} #{msg}")
        Events.broadcast_agent_line(task.id, "\n[toolchain: #{msg}]\n")
        state.tracker.update_status(state.tracker_config, task.id, "failed")
        state
    end
  end

  @doc false
  def spawn_worker(state, task) do
    # CI/review-resume and retry also land here and skip the tick preflight gate.
    if valid_preflight?(state) do
      do_spawn_worker(state, task)
    else
      Logger.warning("orchestrator: refusing spawn for #{task.id}; workflow preflight failed")
      state
    end
  end

  defp do_spawn_worker(state, task) do
    run_id = "run_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    opts = [
      agents: state.agents,
      workspace_root: state.workspace_root,
      workspace_isolation: isolation_opt(state.workspace_isolation),
      workspace_git_repo: state.workspace_git_repo,
      tracker: state.tracker,
      tracker_config: state.tracker_config,
      run_id: run_id
    ]

    parent = self()

    agent_config = AgentRunner.resolve!(task.assignee, state.agents)
    runner = AgentRunner.resolve_adapter(agent_config[:adapter])

    Logger.info(
      "orchestrator: spawning #{task.id} → #{agent_config[:display_name]} (#{agent_config[:adapter]})"
    )

    case Task.Supervisor.start_child(task_supervisor(state), fn ->
           result = runner.run(task, AgentRunner.resolve!(task.assignee, state.agents), opts)
           send(parent, {:run_exit, task.id, result})
           result
         end) do
      {:ok, pid} ->
        # One-shot approval: clear only after a real worker starts (re-gate if
        # the agent fails back to todo). A supervisor {:error, _} must not burn
        # the permit or the next tick cannot retry gated work.
        state = %{
          state
          | approved_once: MapSet.delete(state.approved_once, task.id),
            overage_once: MapSet.delete(state.overage_once || MapSet.new(), task.id)
        }

        Budget.clear_hold(task.id)
        register_spawned_worker(state, task, pid, run_id)

      {:error, reason} ->
        # Do not crash the poll loop. Keep existing claims and one-shot permits
        # so the task stays eligible on a later tick.
        Logger.error("orchestrator: spawn failed for #{task.id}: #{inspect(reason)}")
        state
    end
  end

  defp task_supervisor(%{task_supervisor: sup}) when not is_nil(sup), do: sup
  defp task_supervisor(_), do: Svarm.TaskSup

  defp register_spawned_worker(state, task, pid, run_id) do
    mref = Process.monitor(pid)
    state.tracker.update_status(state.tracker_config, task.id, "in_progress")

    Logger.info(
      "dispatched task #{task.id} (#{task.assignee || "default"}) → pid #{inspect(pid)}"
    )

    %{
      state
      | running:
          Map.put(state.running, task.id, %{
            task: task,
            pid: pid,
            mref: mref,
            run_id: run_id,
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          }),
        claimed: MapSet.put(state.claimed, task.id)
    }
  end

  defp isolation_opt(mode) when mode in [:path, :worktree], do: mode
  defp isolation_opt(_), do: :path
end
