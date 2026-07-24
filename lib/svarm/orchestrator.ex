defmodule Svarm.Orchestrator do
  @moduledoc """
  Orchestrator: Symphony-compatible poll loop. Plain GenServer.

  Tick:     reconcile (stall + tracker state sync §8.5–8.6) → preflight (§6.3) → fetch eligible → dispatch.
  Dispatch: claim → spawn an agent runner task under the Task.Supervisor → monitor.
  Exit:     normal exit → completed (or continuation retry); crash → backoff retry.
  Retry:    `delay = min(10_000 * 2^(attempt-1), max_retry_backoff_ms)`.

  Reconcile now syncs running/claimed tasks against the tracker adapter (external
  terminal states stop workers). Workspace keys use issue source_id per §4.2.

  Issues are fetched via the Svarm.Tracker behaviour, resolved from
  WORKFLOW.md config at boot.
  """
  use GenServer

  require Logger

  alias Svarm.{AgentRunner, Approval, Events, Tracker, Usage, Workflow, Workspace}
  alias Svarm.Workflow.Config, as: WorkflowConfig

  @default_poll_interval_ms 30_000
  @default_max_concurrent 3
  @default_stall_timeout_ms 5 * 60_000
  @default_max_retry_backoff_ms 5 * 60_000
  @default_max_retries 5
  @default_active_states ["todo", "in_progress"]
  @default_terminal_states ["done", "failed", "review"]
  @base_backoff_ms 10_000
  @continuation_retry_ms 1_000

  defstruct [
    :poll_interval_ms,
    :max_concurrent,
    :stall_timeout_ms,
    :max_retry_backoff_ms,
    :max_retries,
    :workspace_root,
    :agents,
    :workflow,
    :approval,
    :tracker,
    :tracker_config,
    :runner,
    active_states: @default_active_states,
    terminal_states: @default_terminal_states,
    running: %{},
    retry_attempts: %{},
    claimed: MapSet.new(),
    completed: MapSet.new(),
    last_run_entries: %{},
    last_tick_mono_ms: nil
  ]

  ## API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Run one poll cycle immediately (used by `mix svarm.demo`)."
  def kick, do: send(__MODULE__, :tick)

  ## init

  @impl true
  def init(opts) do
    state = %__MODULE__{
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      max_concurrent: Keyword.get(opts, :max_concurrent, @default_max_concurrent),
      stall_timeout_ms: Keyword.get(opts, :stall_timeout_ms, @default_stall_timeout_ms),
      max_retry_backoff_ms:
        Keyword.get(opts, :max_retry_backoff_ms, @default_max_retry_backoff_ms),
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      workspace_root: Keyword.get(opts, :workspace_root) || Workspace.default_root(),
      active_states: Keyword.get(opts, :active_states, @default_active_states),
      terminal_states: Keyword.get(opts, :terminal_states, @default_terminal_states),
      agents: %{}
    }

    {:ok, state, {:continue, :load_agents}}
  end

  @impl true
  def handle_continue(:load_agents, state) do
    agents =
      case AgentRunner.load_agents() do
        %{} = m ->
          m

        {:error, reason} ->
          Logger.error("agents.toml load failed: #{inspect(reason)}; dispatch disabled")
          %{}
      end

    workflow = Workflow.Store.get()

    state =
      %{state | agents: agents, workflow: workflow}
      |> apply_workflow_config()
      |> put_approval_config()
      |> resolve_tracker()
      |> resolve_runner()
      # §8.6 startup cleanup: run tracker reconcile on boot (running/claimed start empty,
      # but ensures consistent view before first dispatch + catches any future reloads)
      |> reconcile_tracker_states()

    send(self(), :tick)
    {:noreply, state}
  end

  ## tick

  @impl true
  def handle_info(:tick, state) do
    state = reconcile(state)
    state = if valid_preflight?(state), do: dispatch(state), else: state
    state = %{state | last_tick_mono_ms: System.monotonic_time(:millisecond)}
    Process.send_after(self(), :tick, state.poll_interval_ms)
    broadcast_status(state)
    {:noreply, state}
  end

  ## worker exit (graceful)

  def handle_info({:run_exit, task_id, result}, state) do
    case Map.pop(state.running, task_id) do
      {nil, _running} ->
        {:noreply, state}

      {entry, running} ->
        {:noreply, handle_run_exit(%{state | running: running}, entry, task_id, result)}
    end
  end

  ## worker crash

  def handle_info({:DOWN, mref, :process, _pid, reason}, state) do
    if is_nil(state.running) or is_nil(state.claimed) do
      {:noreply, state}
    else
      {task_id, _entry} =
        Enum.find(state.running, fn {_id, e} -> e.mref == mref end) || {nil, nil}

      if task_id == nil do
        {:noreply, state}
      else
        {entry, state} = Map.pop(state.running, task_id)
        state = %{state | claimed: MapSet.delete(state.claimed, task_id)}
        state = Map.update!(state, :last_run_entries, &Map.put(&1, task_id, entry))
        Logger.warning("worker crashed for #{task_id}: #{inspect(reason)}")
        state = schedule_retry(state, entry.task, {:crash, reason})
        {:noreply, state}
      end
    end
  end

  ## retry timer

  def handle_info({:retry, task_id}, state) do
    {entry, retry_map} = Map.pop(state.retry_attempts, task_id)
    state = %{state | retry_attempts: retry_map}
    {:noreply, do_retry(state, entry, task_id)}
  end

  def handle_info({:workflow_reloaded, wf}, state) do
    Logger.info("workflow reloaded from #{wf.path}")

    state =
      %{state | workflow: wf}
      |> apply_workflow_config()
      |> put_approval_config()
      |> resolve_tracker()
      |> resolve_runner()

    {:noreply, state}
  end

  def handle_info(other, state) do
    Logger.debug("orchestrator: ignored #{inspect(other)}")
    {:noreply, state}
  end

  defp do_retry(state, entry, task_id) do
    case state.tracker.get_issue(state.tracker_config, task_id) do
      {:ok, task} ->
        if task.status in state.terminal_states do
          %{state | claimed: MapSet.delete(state.claimed, task_id)}
        else
          retry_or_spawn(state, task, task_id, entry)
        end

      {:error, _} ->
        Logger.info("retry: task #{task_id} gone, releasing claim")
        %{state | claimed: MapSet.delete(state.claimed, task_id)}
    end
  end

  defp retry_or_spawn(state, task, task_id, entry) do
    if slots_available?(state) do
      spawn_worker(state, task)
    else
      timer = Process.send_after(self(), {:retry, task_id}, @continuation_retry_ms)
      retry = Map.put(entry || %{}, :timer, timer)
      %{state | retry_attempts: Map.put(state.retry_attempts, task_id, retry)}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_summary(state), state}
  end

  ## reconcile: stall detection + tracker state sync (§8.5–§8.6)
  # Per-tick: kill stalled workers, then refresh state from tracker for any
  # in-flight (running/claimed/retrying) tasks. If tracker now shows terminal
  # (e.g. human closed the issue), stop worker and drop from our sets.
  # Startup cleanup is achieved by the first tick's reconcile + dispatch filters.

  defp reconcile(state) do
    state
    |> reconcile_stalls()
    |> reconcile_tracker_states()
  end

  defp reconcile_stalls(%{stall_timeout_ms: stall} = state) when stall <= 0, do: state

  defp reconcile_stalls(state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.running, state, fn {task_id, e}, acc ->
      if now - e.started_mono_ms > state.stall_timeout_ms do
        Logger.warning("stall: killing worker for #{task_id}")
        Process.exit(e.pid, :stall)

        acc = %{
          acc
          | running: Map.delete(acc.running, task_id),
            claimed: MapSet.delete(acc.claimed, task_id)
        }

        schedule_retry(acc, e.task, :stall)
      else
        acc
      end
    end)
  end

  # Tracker reconcile (P0 for v1 correctness): pull current status for active
  # tasks. External terminal states (or missing issue) → stop worker + release claim.
  # Safe: tracker errors are logged and ignored so one bad tick doesn't kill loop.
  defp reconcile_tracker_states(state) do
    ids =
      (Map.keys(state.running) ++ MapSet.to_list(state.claimed) ++ Map.keys(state.retry_attempts))
      |> Enum.uniq()

    Enum.reduce(ids, state, fn task_id, acc ->
      case safe_get_issue(acc.tracker, acc.tracker_config, task_id) do
        {:ok, issue} -> maybe_release_if_terminal(acc, task_id, issue)
        {:error, _} -> release_task(acc, task_id)
      end
    end)
  end

  defp maybe_release_if_terminal(acc, task_id, issue) do
    if issue.status in acc.terminal_states do
      Logger.info("tracker reconcile: #{task_id} now terminal (#{issue.status}), stopping")
      release_task(acc, task_id)
    else
      acc
    end
  end

  defp release_task(state, task_id) do
    state = stop_worker_if_running(state, task_id, :tracker_terminal)

    retry_entry = Map.get(state.retry_attempts, task_id)

    if retry_entry && retry_entry[:timer] do
      Process.cancel_timer(retry_entry.timer)
    end

    %{
      state
      | claimed: MapSet.delete(state.claimed, task_id),
        retry_attempts: Map.delete(state.retry_attempts, task_id)
    }
  end

  defp safe_get_issue(tracker, config, id) do
    tracker.get_issue(config, id)
  rescue
    e in [ArgumentError, KeyError, ErlangError] ->
      Logger.warning("reconcile_tracker get_issue failed for #{id}: #{inspect(e)}")
      {:error, {:tracker_error, e}}
  end

  defp stop_worker_if_running(state, task_id, reason) do
    case Map.pop(state.running, task_id) do
      {nil, _} ->
        state

      {entry, running} ->
        Process.exit(entry.pid, reason)
        %{state | running: running}
    end
  end

  ## dispatch

  defp valid_preflight?(%{agents: agents, workflow: nil}), do: map_size(agents) > 0
  defp valid_preflight?(%{agents: agents}) when map_size(agents) == 0, do: false

  defp valid_preflight?(%{workflow: wf}) do
    WorkflowConfig.validate_workflow(wf) == :ok
  end

  defp apply_workflow_config(%{workflow: nil} = state) do
    %{
      state
      | tracker_config: %{
          kind: :local,
          active_states: state.active_states,
          terminal_states: state.terminal_states,
          ignored_assignees: []
        }
    }
  end

  defp apply_workflow_config(%{workflow: wf} = state) do
    cfg = WorkflowConfig.from(wf)

    poll_ms =
      case Application.get_env(:svarm, :orchestrator_poll_interval_ms) do
        ms when is_integer(ms) -> ms
        _ -> cfg.poll_interval_ms
      end

    workspace_root =
      case Application.get_env(:svarm, :orchestrator_workspace_root) do
        path when is_binary(path) -> Path.expand(path)
        _ -> cfg.workspace_root
      end

    max_concurrent =
      case Application.get_env(:svarm, :orchestrator_max_concurrent) do
        n when is_integer(n) -> n
        _ -> cfg.max_concurrent
      end

    %{
      state
      | poll_interval_ms: poll_ms,
        max_concurrent: max_concurrent,
        max_retry_backoff_ms: cfg.max_retry_backoff_ms,
        stall_timeout_ms: cfg.stall_timeout_ms,
        workspace_root: workspace_root,
        active_states: cfg.active_states,
        terminal_states: cfg.terminal_states,
        tracker_config: cfg.tracker_config
    }
  end

  defp put_approval_config(%{workflow: nil} = state),
    do: %{state | approval: Approval.config_from_map(%{})}

  defp put_approval_config(%{workflow: wf} = state) do
    %{state | approval: Approval.config_from_map(wf.config)}
  end

  defp resolve_tracker(state) do
    tc = state.tracker_config

    {adapter, config} =
      case tc[:kind] || :local do
        :github ->
          {Tracker.GitHub, tc}

        _ ->
          {Tracker.Local,
           %{
             active_states: tc[:active_states] || state.active_states,
             terminal_states: tc[:terminal_states] || state.terminal_states,
             ignored_assignees: Map.get(tc, :ignored_assignees, [])
           }}
      end

    %{state | tracker: adapter, tracker_config: config}
  end

  defp resolve_runner(state) do
    %{state | runner: :per_agent}
  end

  defp dispatch(state) do
    case state.tracker.list_eligible(state.tracker_config) do
      {:ok, candidates} ->
        Enum.reduce_while(candidates, state, fn task, acc ->
          if slots_full?(acc), do: {:halt, acc}, else: process_candidate(acc, task)
        end)

      {:error, reason} ->
        Logger.warning("list_eligible failed: #{inspect(reason)}")
        state
    end
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
          Map.has_key?(acc.retry_attempts, task.id) ->
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
        case acc.tracker.get_issue(acc.tracker_config, dep_id) do
          {:ok, dep} -> dep.status in acc.terminal_states
          _ -> true
        end

      _ ->
        false
    end
  end

  defp maybe_gate_or_spawn(state, task) do
    if Approval.required?(state.approval, task, state.agents) do
      :ok = state.tracker.update_status(state.tracker_config, task.id, Approval.pending_status())
      Logger.info("task #{task.id} held for human approval")
      state
    else
      spawn_worker(state, task)
    end
  end

  defp slots_available?(%{running: running, max_concurrent: mc}), do: map_size(running) < mc

  defp handle_run_exit(state, entry, task_id, result) do
    state =
      state
      |> Map.update!(:claimed, &MapSet.delete(&1, task_id))
      |> Map.update!(:last_run_entries, &Map.put(&1, task_id, entry))

    handle_result(state, task_id, result)
  end

  defp spawn_worker(state, task) do
    run_id = "run_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    opts = [
      agents: state.agents,
      workspace_root: state.workspace_root,
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

    {:ok, pid} =
      Task.Supervisor.start_child(Svarm.TaskSup, fn ->
        result = runner.run(task, AgentRunner.resolve!(task.assignee, state.agents), opts)
        send(parent, {:run_exit, task.id, result})
        result
      end)

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

  defp handle_result(state, task_id, :ok) do
    case state.tracker.get_issue(state.tracker_config, task_id) do
      {:ok, task} ->
        if task.status in state.terminal_states do
          Logger.info("task #{task_id} succeeded")
          post_run_summary(state, task_id, :ok)
          %{state | completed: MapSet.put(state.completed, task_id)}
        else
          Logger.info("task #{task_id} normal exit but still active, scheduling continuation")
          schedule_continuation(state, task)
        end

      {:error, _} ->
        Logger.info("task #{task_id} succeeded (issue gone from tracker)")
        post_run_summary(state, task_id, :ok)
        %{state | completed: MapSet.put(state.completed, task_id)}
    end
  end

  defp handle_result(state, task_id, {:error, reason}) do
    task =
      case state.tracker.get_issue(state.tracker_config, task_id) do
        {:ok, t} -> t
        _ -> nil
      end

    schedule_retry(%{state | completed: MapSet.delete(state.completed, task_id)}, task, reason)
  end

  defp post_run_summary(state, task_id, result) do
    if state.tracker == Tracker.Local do
      :ok
    else
      entry = state.last_run_entries[task_id]
      if entry, do: build_and_post(state, task_id, result, entry)
    end
  end

  defp build_and_post(state, task_id, result, entry) do
    task = entry.task
    assignee = task.assignee || "default"
    agent = Map.get(state.agents, assignee, %{})

    summary = %{
      run_id: entry[:run_id],
      task_id: task_id,
      task: task,
      result: result,
      duration_ms: System.monotonic_time(:millisecond) - entry.started_mono_ms,
      agent_name: agent[:display_name] || assignee,
      agent_role: blank_to_nil(agent[:role]),
      adapter: agent[:adapter],
      harness: harness_label(agent),
      model: agent[:model],
      provider: agent[:provider],
      cost: Usage.task_cost(task_id),
      total_tokens: total_tokens_for_task(task_id),
      branch: nil,
      exit_code: exit_code_from_result(result)
    }

    state.tracker.post_run_summary(state.tracker_config, task_id, summary)
  end

  defp harness_label(%{adapter: "pi_rpc"}), do: "Pi"

  defp harness_label(%{adapter: "cli", command: command}) when is_binary(command) do
    cond do
      String.contains?(command, "claude") -> "Claude Code"
      String.contains?(command, "codex") -> "Codex CLI"
      true -> "CLI Agent"
    end
  end

  defp harness_label(_), do: "Unknown"

  defp exit_code_from_result(:ok), do: 0
  defp exit_code_from_result({:error, _}), do: 1

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  defp total_tokens_for_task(task_id) do
    Usage.for_task(task_id)
    |> Enum.reduce(0, fn r, acc -> acc + (r.prompt_tokens || 0) + (r.completion_tokens || 0) end)
  end

  ## retry / backoff

  defp schedule_continuation(state, task) do
    timer = Process.send_after(self(), {:retry, task.id}, @continuation_retry_ms)

    entry = %{
      attempt: task.attempts || 0,
      identifier: task.id,
      due_at_mono: System.monotonic_time(:millisecond) + @continuation_retry_ms,
      timer: timer
    }

    %{state | retry_attempts: Map.put(state.retry_attempts, task.id, entry)}
  end

  defp schedule_retry(state, nil, _reason), do: state

  defp schedule_retry(state, task, reason) do
    task_id = task.id
    next = (task.attempts || 0) + 1
    state.tracker.update_attempts(state.tracker_config, task_id, next)

    if next > state.max_retries do
      Logger.error("task #{task_id} exhausted #{state.max_retries} retries → human escalation")
      state.tracker.update_status(state.tracker_config, task_id, "failed")
      post_run_summary(state, task_id, {:error, reason})
      %{state | claimed: MapSet.delete(state.claimed, task_id)}
    else
      delay = backoff(state, next)
      Logger.info("task #{task_id} retry #{next} in #{delay}ms (#{inspect(reason)})")
      timer = Process.send_after(self(), {:retry, task_id}, delay)

      entry = %{
        attempt: next,
        identifier: task_id,
        due_at_mono: System.monotonic_time(:millisecond) + delay,
        timer: timer
      }

      %{state | retry_attempts: Map.put(state.retry_attempts, task_id, entry)}
    end
  end

  defp backoff(state, attempt) do
    (@base_backoff_ms * trunc(:math.pow(2, attempt - 1)))
    |> min(state.max_retry_backoff_ms)
  end

  defp broadcast_status(state) do
    Events.broadcast_orchestrator_status(status_summary(state))
  end

  defp status_summary(state) do
    active_assignees =
      state.running
      |> Enum.map(fn {_id, entry} -> entry.task.assignee end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    running_started =
      Map.new(state.running, fn {id, entry} -> {id, entry.started_mono_ms} end)

    %{
      poll_interval_ms: state.poll_interval_ms,
      max_concurrent: state.max_concurrent,
      approval: state.approval,
      running: map_size(state.running),
      claimed: MapSet.size(state.claimed),
      retrying: map_size(state.retry_attempts),
      completed: MapSet.size(state.completed),
      running_ids: Map.keys(state.running),
      retry_ids: Map.keys(state.retry_attempts),
      active_assignees: active_assignees,
      active_agent_count: length(active_assignees),
      running_started: running_started,
      last_tick_mono_ms: state.last_tick_mono_ms
    }
  end
end
