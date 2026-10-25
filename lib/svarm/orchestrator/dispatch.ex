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
    KanbanBridge,
    Toolchain
  }

  alias Svarm.Orchestrator.{Issues, Scope, Status}
  alias Svarm.Settings.Resolve, as: SettingsResolve
  alias Svarm.Tracker.Resolve, as: TrackerResolve

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

    case Scope.enabled_boards(state) do
      :legacy ->
        dispatch_tracker(state)

      boards ->
        Enum.reduce(boards, state, fn board, acc ->
          original = {acc.tracker, acc.tracker_config}
          acc = put_board_tracker(acc, board)
          acc = dispatch_tracker(acc)
          {tracker, config} = original
          %{acc | tracker: tracker, tracker_config: config}
        end)
    end
  end

  defp put_board_tracker(state, board) do
    base = SettingsResolve.tracker_config(board.tracker || %{})

    {adapter, config} =
      TrackerResolve.adapter_and_config(
        config: base,
        active_states: state.active_states,
        terminal_states: state.terminal_states
      )

    %{state | tracker: adapter, tracker_config: Map.put(config, :board_id, board.id)}
  end

  defp dispatch_tracker(state) do
    case state.tracker.list_eligible(state.tracker_config) do
      {:ok, candidates} ->
        dep_ids =
          candidates
          |> Enum.flat_map(fn task -> List.wrap(Map.get(task, :depends_on) || []) end)
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        state = Issues.prefetch(state, dep_ids)

        Enum.reduce(candidates, state, fn task, acc ->
          process_candidate(acc, prepare_task(acc, task))
        end)

      {:error, reason} ->
        Logger.warning("list_eligible failed: #{inspect(reason)}")
        state
    end
  end

  defp prepare_task(state, task) do
    if Scope.catalog?(state) do
      board_id = state.tracker_config[:board_id]
      external = Scope.external_id(task)
      task = %{task | board_id: board_id, external_task_id: external}
      sync_task_row(task)
    else
      task
    end
  end

  defp sync_task_row(task) do
    locator = workspace_locator(task)

    KanbanBridge.upsert_external(task.board_id, task.external_task_id, %{
      id: task.id,
      title: task.title || "untitled",
      status: task.status || "todo",
      assignee: task.assignee,
      body: task.body,
      attempts: task.attempts || 0,
      workspace_locator: locator
    })

    %{task | workspace_locator: locator}
  end

  defp workspace_locator(%{workspace_locator: loc}) when is_binary(loc) and loc != "", do: loc
  defp workspace_locator(%{board_id: board_id, id: id}), do: "#{board_id}/#{id}"

  # Eligibility is checked in two layers:
  # 1. Adapter level (Eligibility.eligible?): tracker-specific rules
  #    (e.g., GitHub: required labels, exclude PRs, skip human assignees)
  # 2. Orchestrator level (process_candidate): cross-cutting rules
  #    (running/claimed, terminal states, pending approval)
  # This ensures the orchestrator never dispatches an issue that's already
  # in flight, even if the adapter missed it.
  defp process_candidate(acc, task) do
    key = Scope.run_key(acc, task)

    cond do
      not Scope.admit?(acc, task) ->
        acc

      MapSet.member?(acc.claimed, key) or
        Map.has_key?(acc.retry_attempts, key) or
          MapSet.member?(acc.completed, key) ->
        acc

      task.status in acc.terminal_states ->
        acc

      task.status == Approval.pending_status() ->
        acc

      not dependencies_met?(task, acc) ->
        acc

      true ->
        maybe_gate_or_spawn(acc, task)
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

      not MapSet.member?(state.approved_once, Scope.run_key(state, task)) and
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
    if MapSet.member?(state.overage_once || MapSet.new(), Scope.run_key(state, task)) do
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

    git = state.workspace_git || %{}

    opts = [
      agents: state.agents,
      workspace_root: state.workspace_root,
      workspace_isolation: isolation_opt(state.workspace_isolation),
      workspace_git_repo: git[:repo],
      workspace_git_remote: git[:remote],
      workspace_git_token: git[:token],
      tracker: state.tracker,
      tracker_config: state.tracker_config,
      run_id: run_id
    ]

    parent = self()
    run_key = Scope.run_key(state, task)

    agent_config = AgentRunner.resolve!(task.assignee, state.agents)
    runner = AgentRunner.resolve_adapter(agent_config[:adapter])

    Logger.info(
      "orchestrator: spawning #{task.id} → #{agent_config[:display_name]} (#{agent_config[:adapter]})"
    )

    case Task.Supervisor.start_child(task_supervisor(state), fn ->
           result = runner.run(task, AgentRunner.resolve!(task.assignee, state.agents), opts)
           send(parent, {:run_exit, run_key, result})
           result
         end) do
      {:ok, pid} ->
        # One-shot approval: clear only after a real worker starts (re-gate if
        # the agent fails back to todo). A supervisor {:error, _} must not burn
        # the permit or the next tick cannot retry gated work. Same lifetime for
        # the follow-up note: the worker already holds `task`, so clearing the
        # tracker copy cannot remove it from this spawn's prompt.
        state = %{
          state
          | approved_once: MapSet.delete(state.approved_once, run_key),
            overage_once: MapSet.delete(state.overage_once || MapSet.new(), run_key)
        }

        state = maybe_clear_follow_up(state, task)
        Budget.clear_hold(task.id)
        register_spawned_worker(state, task, pid, run_id, run_key)

      {:error, reason} ->
        # Do not crash the poll loop. Keep existing claims and one-shot permits
        # so the task stays eligible on a later tick.
        Logger.error("orchestrator: spawn failed for #{task.id}: #{inspect(reason)}")
        state
    end
  end

  defp task_supervisor(%{task_supervisor: sup}) when not is_nil(sup), do: sup
  defp task_supervisor(_), do: Svarm.TaskSup

  # One-shot follow-up: consumption is the spawn itself. Only touch the
  # tracker when this task actually carried a queued note (avoids a REST
  # GET+PATCH on every ordinary dispatch). Failure to clear is logged, never
  # fatal — a stale marker still reads as already-consumed metadata.
  defp maybe_clear_follow_up(state, %{follow_up: text} = task)
       when is_binary(text) and text != "" do
    case state.tracker.update_follow_up(state.tracker_config, task.id, nil) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("orchestrator: follow-up clear failed for #{task.id}: #{inspect(reason)}")
        state
    end
  end

  defp maybe_clear_follow_up(state, _task), do: state

  defp register_spawned_worker(state, task, pid, run_id, run_key) do
    mref = Process.monitor(pid)
    state.tracker.update_status(state.tracker_config, task.id, "in_progress")

    Logger.info(
      "dispatched task #{task.id} (#{task.assignee || "default"}) → pid #{inspect(pid)}"
    )

    %{
      state
      | running:
          Map.put(state.running, run_key, %{
            task: task,
            pid: pid,
            mref: mref,
            run_id: run_id,
            board_id: task.board_id,
            tracker: state.tracker,
            tracker_config: state.tracker_config,
            started_mono_ms: System.monotonic_time(:millisecond),
            started_at: System.system_time(:second)
          }),
        claimed: MapSet.put(state.claimed, run_key)
    }
  end

  defp isolation_opt(mode) when mode in [:path, :worktree, :clone], do: mode
  defp isolation_opt(_), do: :path
end
