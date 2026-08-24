defmodule Svarm.Orchestrator do
  @moduledoc """
  Orchestrator: Symphony-compatible poll loop. Plain GenServer.

  Tick:     reconcile (stall + tracker state sync §8.5–8.6) → maybe_ci_resume
            (GitHub CI Evidence for review+PR; optional resume spawn) →
            maybe_review_resume → preflight (§6.3) → fetch eligible → dispatch.
  Dispatch: claim → spawn an agent runner task under the Task.Supervisor → monitor.
  Exit:     normal exit → completed (force `review` if tracker still active);
  crash → backoff retry. Multi-turn re-spawn is not used: runners that need
  another turn should return an explicit continue signal in a future revision.
  Retry:    `delay = min(10_000 * 2^(attempt-1), max_retry_backoff_ms)`.

  CI poll: on GitHub, refresh Checks summary onto coordination for Review Station
  Evidence (pass/fail/pending/unknown). When `ci_resume.enabled`, also re-open for
  a fresh agent run with failure context until the circuit opens after N attempts.
  See `Svarm.CiResume` / issue #156.

  Review-resume: poll GitHub PR reviews for managed PRs in review and record
  changes-requested state (board chip). When `review_resume.enabled`, the first
  transition into changes-requested re-opens for a fresh run with review
  context, sharing the CI resume circuit. See `Svarm.ReviewResume`.

  Reconcile now syncs running/claimed tasks against the tracker adapter (external
  terminal states stop workers). Workspace keys use issue source_id per §4.2.

  Issues are fetched via the Svarm.Tracker behaviour. `Svarm.Tracker.Resolve`
  maps kind → `{adapter, config}` at boot; CI/review poll is a capability, not
  a Local-module identity check.
  """
  use GenServer

  require Logger

  alias Svarm.{
    AgentQuestion,
    AgentRunner,
    Approval,
    Budget,
    CiResume,
    Coordination,
    Demo,
    Events,
    ReviewResume,
    Settings,
    Toolchain,
    Tracker,
    Usage,
    Workflow,
    Workspace
  }

  alias Svarm.Tracker.GitHub.Checks
  alias Svarm.Tracker.GitHub.Reviews

  alias Svarm.Workflow.Config, as: WorkflowConfig

  @default_poll_interval_ms 30_000
  @default_max_concurrent 3
  @default_stall_timeout_ms 45 * 60_000
  @default_max_retry_backoff_ms 5 * 60_000
  @default_max_retries 5
  @default_active_states ["todo", "in_progress"]
  @default_terminal_states ["done", "failed", "review"]
  @base_backoff_ms 10_000
  @continuation_retry_ms 1_000
  # Force-terminal status patch after ok exit: retry without blocking the GenServer.
  @force_terminal_max_attempts 3
  @force_terminal_backoff_ms 400
  # Bound Checks / review polls per tick so the GenServer mailbox stays responsive.
  @ci_resume_max_per_tick 3
  @review_resume_max_per_tick 3

  defstruct [
    :poll_interval_ms,
    :max_concurrent,
    :stall_timeout_ms,
    :max_retry_backoff_ms,
    :max_retries,
    :workspace_root,
    :workspace_isolation,
    :workspace_git_repo,
    :agents,
    :workflow,
    :approval,
    :tracker,
    :tracker_config,
    :runner,
    :last_budget_block,
    active_states: @default_active_states,
    terminal_states: @default_terminal_states,
    running: %{},
    retry_attempts: %{},
    claimed: MapSet.new(),
    completed: MapSet.new(),
    approved_once: MapSet.new(),
    overage_once: MapSet.new(),
    budget_caps: %{},
    budget_mode: :hard,
    ci_resume_caps: %{enabled: false, max_attempts: 3, skip_draft: true},
    review_resume_caps: %{enabled: false},
    last_run_entries: %{},
    last_tick_mono_ms: nil,
    task_supervisor: Svarm.TaskSup
  ]

  ## API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Run one poll cycle immediately (used by `mix svarm.demo`)."
  def kick, do: send(__MODULE__, :tick)

  @doc """
  Record a human one-shot approval so the next poll can dispatch without
  re-entering `pending_approval`. Cleared after the first spawn attempt.
  """
  def mark_approved(task_id) when is_binary(task_id) do
    GenServer.cast(__MODULE__, {:mark_approved, task_id})
  end

  @doc """
  Record a one-shot overage approval so the next poll can spawn despite the cap.
  Cleared after the first spawn attempt.
  """
  def mark_overage_approved(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:mark_overage_approved, task_id})
  end

  @doc """
  Reload agents from file+Settings and re-apply workflow/tracker overlay.
  Used by `/setup` Apply — no BEAM restart.
  """
  def reload_config, do: GenServer.call(__MODULE__, :reload_config)

  @doc """
  Abort a live agent run (board **Abort**).

  Invokes the shared OS kill-tree (`AgentRunner.kill_os_tree/1`) before
  exiting the worker, drops the task from the running set so `:DOWN` cannot
  crash-retry the same run, and returns the ticket to `todo`.
  """
  @spec abort(String.t()) :: :ok | {:error, :not_running}
  def abort(task_id) when is_binary(task_id) do
    # Kill-tree + worker wait (2s) + tracker patch; keep well under this.
    GenServer.call(__MODULE__, {:abort, task_id}, 15_000)
  end

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
      workspace_isolation: Keyword.get(opts, :workspace_isolation, :path),
      workspace_git_repo: Keyword.get(opts, :workspace_git_repo),
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
    state = maybe_ci_resume(state)
    state = maybe_review_resume(state)
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
        {entry, running} = Map.pop(state.running, task_id)

        state =
          %{state | running: running, claimed: MapSet.delete(state.claimed, task_id)}
          |> Map.update!(:last_run_entries, &Map.put(&1, task_id, entry))

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

  ## force-terminal status patch (non-blocking retries)

  def handle_info({:force_terminal_retry, task_id, status, attempt}, state) do
    force_terminal_status(state, task_id, status, attempt)
    {:noreply, state}
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
    cond do
      not valid_preflight?(state) ->
        # Same as no-slot: keep the retry so a later valid reload can resume.
        # Tick dispatch is already gated; retries used to skip that check.
        Logger.debug("retry: #{task_id} deferred; workflow preflight failed")
        defer_retry(state, task_id, entry)

      slots_available?(state) ->
        # Same hard caps as first dispatch — retries are still new agent processes
        maybe_budget_or_spawn(state, task)

      true ->
        defer_retry(state, task_id, entry)
    end
  end

  defp defer_retry(state, task_id, entry) do
    timer = Process.send_after(self(), {:retry, task_id}, @continuation_retry_ms)
    retry = Map.put(entry || %{}, :timer, timer)
    %{state | retry_attempts: Map.put(state.retry_attempts, task_id, retry)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_summary(state), state}
  end

  def handle_call(:reload_config, _from, state) do
    agents =
      case AgentRunner.load_agents() do
        %{} = m ->
          m

        {:error, reason} ->
          Logger.error("reload_config: agents load failed: #{inspect(reason)}")
          %{}

        _ ->
          %{}
      end

    workflow = Workflow.Store.get()

    state =
      %{state | agents: agents, workflow: workflow}
      |> apply_workflow_config()
      |> put_approval_config()
      |> resolve_tracker()
      |> resolve_runner()

    summary = %{
      agent_count: map_size(state.agents),
      tracker_kind: state.tracker_config[:kind] || :local,
      default_model: get_in(state.agents, ["default", :model])
    }

    Logger.info("reload_config: agents=#{summary.agent_count} tracker=#{summary.tracker_kind}")

    broadcast_status(state)
    {:reply, {:ok, summary}, state}
  end

  @impl true
  def handle_call({:mark_overage_approved, task_id}, _from, state) when is_binary(task_id) do
    {:reply, :ok,
     %{state | overage_once: MapSet.put(state.overage_once || MapSet.new(), task_id)}}
  end

  def handle_call({:abort, task_id}, _from, state) when is_binary(task_id) do
    case Map.pop(state.running, task_id) do
      {nil, _} ->
        {:reply, {:error, :not_running}, state}

      {entry, running} ->
        state = %{
          state
          | running: running,
            claimed: MapSet.delete(state.claimed, task_id)
        }

        state = cancel_retry_for(state, task_id)
        drop_worker_monitor(entry)
        await_worker_exit(entry.pid, :board_abort)
        Events.broadcast_agent_line(task_id, "\n[board] aborted\n")
        state.tracker.update_status(state.tracker_config, task_id, "todo")
        AgentQuestion.clear(task_id)
        broadcast_status(state)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:mark_approved, task_id}, state) when is_binary(task_id) do
    {:noreply, %{state | approved_once: MapSet.put(state.approved_once, task_id)}}
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

  # Stall (and tracker-terminal via stop_worker_if_running/3) calls
  # AgentRunner.kill_os_tree/1 then exits the worker Task. That is the same
  # OS kill-tree as PiRPC/CLI timeout abort (Port process-group / PGID when
  # `pgrep` is absent). try/after in the runner does not run on an external
  # exit; the facade call plus a runner reaper reap hung pi/node/git children
  # so injected tokens are not left behind.
  defp reconcile_stalls(state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.running, state, fn {task_id, e}, acc ->
      if now - e.started_mono_ms > state.stall_timeout_ms do
        Logger.warning("stall: killing worker for #{task_id}")
        kill_worker(e.pid, :stall)

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
  # tasks. External terminal states (or documented gone / :not_found) → stop
  # worker + release claim. Transient tracker errors (network, 5xx, rate-limit,
  # and other non-gone failures) are logged and left in-flight so one bad tick
  # does not kill a healthy run.
  defp reconcile_tracker_states(state) do
    ids =
      (Map.keys(state.running) ++ MapSet.to_list(state.claimed) ++ Map.keys(state.retry_attempts))
      |> Enum.uniq()

    Enum.reduce(ids, state, fn task_id, acc ->
      case safe_get_issue(acc.tracker, acc.tracker_config, task_id) do
        {:ok, issue} -> maybe_release_if_terminal(acc, task_id, issue)
        {:error, reason} -> reconcile_get_issue_error(acc, task_id, reason)
      end
    end)
  end

  defp reconcile_get_issue_error(acc, task_id, reason) do
    if gone_issue?(reason) do
      Logger.info("tracker reconcile: #{task_id} missing (#{inspect(reason)}), releasing")
      release_task(acc, task_id)
    else
      Logger.warning(
        "tracker reconcile: get_issue failed for #{task_id} (#{inspect(reason)}); keeping in-flight work"
      )

      acc
    end
  end

  # Documented gone / missing issue. GitHub get_issue uses the atom; other
  # adapter callbacks use %{type: :not_found} maps — treat both as vanished.
  defp gone_issue?(:not_found), do: true
  defp gone_issue?(%{type: :not_found}), do: true
  defp gone_issue?(_reason), do: false

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
        kill_worker(entry.pid, reason)
        %{state | running: running}
    end
  end

  @doc false
  @spec kill_worker(pid(), term()) :: true
  def kill_worker(pid, reason) when is_pid(pid) do
    AgentRunner.kill_os_tree(pid)
    Process.exit(pid, reason)
  end

  defp drop_worker_monitor(%{mref: mref}) when is_reference(mref) do
    Process.demonitor(mref, [:flush])
  end

  defp drop_worker_monitor(_), do: true

  # Kill-tree first (stall/timeout share this), then wait so a dying runner
  # cannot overwrite the `todo` status we patch next.
  defp await_worker_exit(pid, reason) when is_pid(pid) do
    ref = Process.monitor(pid)
    kill_worker(pid, reason)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2_000 ->
        Logger.warning("abort: worker #{inspect(pid)} still alive after 2s")
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        :ok
    end
  end

  defp cancel_retry_for(state, task_id) do
    case Map.pop(state.retry_attempts, task_id) do
      {nil, map} ->
        %{state | retry_attempts: map}

      {entry, map} ->
        if is_reference(entry[:timer]), do: Process.cancel_timer(entry.timer)
        %{state | retry_attempts: map}
    end
  end

  ## dispatch

  defp valid_preflight?(%{agents: agents, workflow: nil}), do: map_size(agents) > 0
  defp valid_preflight?(%{agents: agents}) when map_size(agents) == 0, do: false

  defp valid_preflight?(%{workflow: wf}) do
    WorkflowConfig.validate_workflow(wf) == :ok
  end

  defp apply_workflow_config(%{workflow: nil} = state) do
    base = %{
      kind: :local,
      active_states: state.active_states,
      terminal_states: state.terminal_states,
      ignored_assignees: []
    }

    %{
      state
      | tracker_config: Settings.Resolve.tracker_overlay(base),
        budget_caps: Budget.load_caps(nil),
        budget_mode: Budget.load_mode(nil),
        ci_resume_caps: CiResume.load_caps(nil),
        review_resume_caps: ReviewResume.load_caps(nil)
    }
  end

  defp apply_workflow_config(%{workflow: wf} = state) do
    cfg = WorkflowConfig.from(wf)
    raw_config = if is_map(wf.config), do: wf.config, else: %{}

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
        workspace_isolation:
          apply_workspace_isolation(cfg.workspace_isolation, state.workspace_isolation),
        workspace_git_repo: Map.get(cfg, :workspace_git_repo),
        active_states: cfg.active_states,
        terminal_states: cfg.terminal_states,
        tracker_config: Settings.Resolve.tracker_overlay(cfg.tracker_config),
        budget_caps: Budget.load_caps(raw_config),
        budget_mode: Budget.load_mode(raw_config),
        ci_resume_caps: CiResume.load_caps(raw_config),
        review_resume_caps: ReviewResume.load_caps(raw_config)
    }
  end

  # from_map/1 stores {:error, :invalid_workspace_isolation} so validate_workflow/1
  # can fail closed. Never copy that tuple into runner-facing state — it is
  # truthy, so `|| :path` would leak it into Workspace.ensure/3.
  defp apply_workspace_isolation(mode, _prev) when mode in [:path, :worktree], do: mode
  defp apply_workspace_isolation(_invalid, prev) when prev in [:path, :worktree], do: prev
  defp apply_workspace_isolation(_invalid, _prev), do: :path

  defp isolation_opt(mode) when mode in [:path, :worktree], do: mode
  defp isolation_opt(_), do: :path

  defp put_approval_config(%{workflow: nil} = state),
    do: %{state | approval: merge_approval_overlay(Approval.config_from_map(%{}))}

  defp put_approval_config(%{workflow: wf} = state) do
    %{state | approval: merge_approval_overlay(Approval.config_from_map(wf.config))}
  end

  # Demo seed may leave :approval_overlay in Application env. Only merge while a
  # demo profile flag is active so long-lived non-demo VMs keep WORKFLOW policy.
  # Restrict-only: never weaken base mode: :all (gate everyone stays gated).
  defp merge_approval_overlay(base) when is_map(base) do
    if Demo.demo_profile_active?() do
      case Application.get_env(:svarm, :approval_overlay) do
        %{} = overlay -> restrict_merge_approval(base, overlay)
        _ -> base
      end
    else
      base
    end
  end

  defp restrict_merge_approval(%{mode: :all} = base, _overlay), do: base

  defp restrict_merge_approval(base, overlay) when is_map(base) and is_map(overlay) do
    Map.merge(base, overlay)
  end

  defp resolve_tracker(state) do
    {adapter, config} =
      Tracker.Resolve.adapter_and_config(
        config: state.tracker_config,
        active_states: state.active_states,
        terminal_states: state.terminal_states
      )

    %{state | tracker: adapter, tracker_config: config}
  end

  defp resolve_runner(state) do
    %{state | runner: :per_agent}
  end

  defp dispatch(state) do
    state = maybe_release_budget_holds(state)

    case state.tracker.list_eligible(state.tracker_config) do
      {:ok, candidates} ->
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
        case acc.tracker.get_issue(acc.tracker_config, dep_id) do
          {:ok, dep} -> dep.status in acc.terminal_states
          _ -> true
        end

      _ ->
        false
    end
  end

  defp maybe_gate_or_spawn(state, task) do
    if budget_held_without_permit?(state, task.id) do
      state
    else
      one_shot? = MapSet.member?(state.approved_once, task.id)

      if not one_shot? and Approval.required?(state.approval, task, state.agents) do
        :ok =
          state.tracker.update_status(state.tracker_config, task.id, Approval.pending_status())

        Logger.info("task #{task.id} held for human approval")
        state
      else
        maybe_budget_or_spawn(state, task)
      end
    end
  end

  defp maybe_budget_or_spawn(state, task) do
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
        :ok =
          state.tracker.update_status(state.tracker_config, task.id, Approval.pending_status())

        :ok = Budget.persist_hold(task.id)
        Logger.info("task #{task.id} held for budget overage approval")
        state
      else
        state
      end

    broadcast_status(state)
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

  defp slots_available?(%{running: running, max_concurrent: mc}), do: map_size(running) < mc

  ## CI poll (board Evidence always; optional resume spawn)

  # Always refresh CI summary for GitHub review+PR cards (Review Station #156).
  # When `ci_resume.enabled`, also evaluate spawn / circuit (issue #44).
  defp maybe_ci_resume(state) do
    if Tracker.Resolve.supports?(state.tracker, :ci_poll) do
      caps = state.ci_resume_caps || %{enabled: false, max_attempts: 3, skip_draft: true}

      state
      |> ci_poll_pr_rows()
      |> Enum.take(@ci_resume_max_per_tick)
      |> Enum.reduce(state, fn coord, acc ->
        maybe_ci_poll_one(acc, coord, caps)
      end)
    else
      state
    end
  end

  # Checks poll is review-scoped. Done+PR rows stay oldest and would starve
  # the 3-slot window if we scanned list_with_pr unbounded. Empty/missing
  # review ids → no poll (do not copy review-resume's unbounded fallback).
  defp ci_poll_pr_rows(state) do
    case review_task_ids(state) do
      [_ | _] = ids ->
        Coordination.list_with_pr(
          limit: @ci_resume_max_per_tick * 2,
          task_ids: ids
        )

      _ ->
        []
    end
  end

  defp maybe_ci_poll_one(state, coord, caps) do
    task_id = coord.task_id

    cond do
      Map.has_key?(state.running, task_id) or MapSet.member?(state.claimed, task_id) ->
        state

      not pr_matches_tracker?(coord, state.tracker_config) ->
        Logger.debug("ci_poll: skip #{task_id} — PR repo does not match tracker")
        state

      not review_status?(state, task_id) ->
        state

      true ->
        evaluate_ci_for_task(state, coord, caps)
    end
  end

  defp pr_matches_tracker?(coord, %{owner: owner, repo: repo})
       when is_binary(owner) and is_binary(repo) do
    Coordination.allowed_repo?(
      %{pr_owner: coord.pr_owner, pr_repo: coord.pr_repo},
      owner: owner,
      repo: repo
    )
  end

  defp pr_matches_tracker?(_coord, _config), do: true

  defp review_status?(state, task_id) do
    case safe_get_issue(state.tracker, state.tracker_config, task_id) do
      {:ok, %{status: "review"}} -> true
      _ -> false
    end
  end

  defp evaluate_ci_for_task(state, coord, caps) do
    checks_mod = Application.get_env(:svarm, :github_checks_module, Checks)

    case checks_mod.summarize_pr_checks(
           coord.pr_owner,
           coord.pr_repo,
           coord.pr_number,
           state.tracker_config,
           skip_draft: Map.get(caps, :skip_draft, true)
         ) do
      {:ok, summary} ->
        decision =
          if Map.get(caps, :enabled, false) do
            CiResume.evaluate(coord, summary, caps)
          else
            :evidence_only
          end

        # Persist conclusion / summary / checked_at on every successful poll.
        # Never write ci_last_head_sha here — that fingerprint is only set
        # after a successful resume reopen (commit_ci_resume). Writing it on
        # :wait / :evidence_only would make a later same-SHA failure :noop.
        store_ci_evidence(coord.task_id, summary)

        case decision do
          :evidence_only -> state
          other -> apply_ci_decision(state, coord, summary, caps, other)
        end

      {:error, reason} ->
        Logger.debug("ci_poll checks error for #{coord.task_id}: #{inspect(reason)}")
        store_ci_evidence_unknown(coord.task_id)
        state
    end
  end

  defp store_ci_evidence(task_id, summary) when is_map(summary) do
    conclusion =
      case Map.get(summary, :conclusion) do
        c when is_atom(c) -> Atom.to_string(c)
        c when is_binary(c) and c != "" -> c
        _ -> "unknown"
      end

    checked_at = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      ci_last_conclusion: conclusion,
      ci_checked_at: checked_at,
      ci_context_summary: Map.get(summary, :summary)
    }

    case Coordination.upsert(task_id, attrs) do
      {:ok, updated} ->
        # Omit status so Events does not spam "[board] status → review" every poll.
        Events.broadcast_task_updated(%{
          id: task_id,
          reason: :ci_evidence,
          ci_conclusion: updated.ci_last_conclusion,
          ci_summary: updated.ci_context_summary,
          ci_checked_at: updated.ci_checked_at
        })

        :ok

      {:error, reason} ->
        Logger.debug("ci_evidence upsert failed for #{task_id}: #{inspect(reason)}")
        :error
    end
  end

  defp store_ci_evidence_unknown(task_id) when is_binary(task_id) do
    checked_at = DateTime.utc_now() |> DateTime.truncate(:second)

    case Coordination.upsert(task_id, %{
           ci_last_conclusion: "unknown",
           ci_checked_at: checked_at,
           ci_context_summary: "CI status unavailable"
         }) do
      {:ok, updated} ->
        Events.broadcast_task_updated(%{
          id: task_id,
          reason: :ci_evidence,
          ci_conclusion: updated.ci_last_conclusion,
          ci_summary: updated.ci_context_summary,
          ci_checked_at: updated.ci_checked_at
        })

        :ok

      {:error, _} ->
        :error
    end
  end

  defp apply_ci_decision(state, _coord, _summary, _caps, :noop), do: state

  defp apply_ci_decision(state, _coord, _summary, _caps, :wait), do: state

  defp apply_ci_decision(state, coord, summary, _caps, :resume) do
    # Reopen first; only fingerprint after status is active so a failed
    # reopen cannot burn the head_sha (evaluate would forever :noop).
    case reopen_for_resume(state, coord.task_id) do
      :ok ->
        commit_ci_resume(state, coord, summary)

      {:error, reason} ->
        Logger.warning(
          "ci_resume: reopen failed for #{coord.task_id}: #{inspect(reason)} (not fingerprinting)"
        )

        state
    end
  end

  defp apply_ci_decision(state, coord, summary, _caps, :circuit_open) do
    case Coordination.upsert(coord.task_id, %{
           ci_circuit_open: true,
           ci_last_conclusion: "failure",
           ci_last_head_sha: summary.head_sha || coord.ci_last_head_sha,
           ci_context_summary: summary.summary || coord.ci_context_summary,
           ci_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
         }) do
      {:ok, _} ->
        Logger.warning("ci_resume: circuit open for #{coord.task_id} (CI retries exhausted)")

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "review",
          reason: :ci_circuit
        })

        broadcast_status(state)
        state

      {:error, reason} ->
        Logger.warning(
          "ci_resume: circuit upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp reopen_for_resume(state, task_id) do
    state.tracker.update_status(state.tracker_config, task_id, "todo")

    case safe_get_issue(state.tracker, state.tracker_config, task_id) do
      {:ok, %{status: status}} when is_binary(status) ->
        if status in state.active_states do
          :ok
        else
          {:error, {:still_not_active, status}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit_ci_resume(state, coord, summary) do
    context = CiResume.context_summary(summary)
    count = (coord.ci_resume_count || 0) + 1

    case Coordination.upsert(coord.task_id, %{
           ci_resume_count: count,
           ci_last_head_sha: summary.head_sha,
           ci_last_conclusion: "failure",
           ci_context_summary: context,
           ci_circuit_open: false,
           ci_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
         }) do
      {:ok, _} ->
        Logger.info(
          "ci_resume: re-opened #{coord.task_id} (attempt #{count}) sha=#{summary.head_sha}"
        )

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "todo",
          reason: :ci_resume
        })

        # One-shot: first-run approval already happened; do not re-gate every CI fix loop.
        %{
          state
          | completed: MapSet.delete(state.completed, coord.task_id),
            approved_once: MapSet.put(state.approved_once, coord.task_id)
        }

      {:error, reason} ->
        Logger.warning(
          "ci_resume: fingerprint upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  ## Review-resume (poll reviews → record state; optional spawn)

  defp maybe_review_resume(state) do
    if Tracker.Resolve.supports?(state.tracker, :review_poll) do
      poll_review_resume(state)
    else
      state
    end
  end

  defp poll_review_resume(state) do
    {next, _polled} =
      state
      |> review_resume_pr_rows()
      |> Enum.reduce_while({state, 0}, &poll_review_resume_step/2)

    next
  end

  # Prefer tracker review ids so done rows cannot fill a bounded window.
  # HTTP 200 with an empty list may still miss configured labels, so we fall
  # back to `list_with_pr` with the same cap of 50 as the happy path. A tagged
  # `list_issues` error must not scan those rows — that was the swallowed-403
  # "poll everything" bug.
  defp review_resume_pr_rows(state) do
    case review_task_ids(state) do
      [_ | _] = ids ->
        Coordination.list_with_pr(
          limit: 50,
          include_circuit_open: true,
          task_ids: ids
        )

      :unavailable ->
        []

      _ ->
        Coordination.list_with_pr(include_circuit_open: true, limit: 50)
    end
  end

  defp review_task_ids(state) do
    if function_exported?(state.tracker, :list_issues, 2) do
      case state.tracker.list_issues(state.tracker_config, status: "review") do
        {:ok, [_ | _] = issues} -> Enum.map(issues, & &1.id)
        {:error, _} -> :unavailable
        _ -> nil
      end
    else
      nil
    end
  end

  defp poll_review_resume_step(_coord, {acc, n}) when n >= @review_resume_max_per_tick do
    {:halt, {acc, n}}
  end

  defp poll_review_resume_step(coord, {acc, n}) do
    {next, polled?} = maybe_review_resume_one(acc, coord)
    {:cont, {next, if(polled?, do: n + 1, else: n)}}
  end

  defp maybe_review_resume_one(state, coord) do
    task_id = coord.task_id

    cond do
      Map.has_key?(state.running, task_id) or MapSet.member?(state.claimed, task_id) ->
        {state, false}

      not pr_matches_tracker?(coord, state.tracker_config) ->
        Logger.debug("review_resume: skip #{task_id} — PR repo does not match tracker")
        {state, false}

      not review_status?(state, task_id) ->
        {state, false}

      true ->
        {evaluate_reviews_for_task(state, coord), true}
    end
  end

  defp evaluate_reviews_for_task(state, coord) do
    reviews_mod = Application.get_env(:svarm, :github_reviews_module, Reviews)

    case reviews_mod.summarize_pr_reviews(
           coord.pr_owner,
           coord.pr_repo,
           coord.pr_number,
           state.tracker_config
         ) do
      {:ok, summary} ->
        decision = ReviewResume.evaluate(coord, summary)

        state
        |> apply_review_decision(coord, summary, decision)
        |> apply_review_spawn(coord, decision)

      {:error, reason} ->
        Logger.debug("review_resume reviews error for #{coord.task_id}: #{inspect(reason)}")
        state
    end
  end

  defp apply_review_decision(state, _coord, _summary, :noop), do: state

  defp apply_review_decision(state, coord, summary, :record) do
    context = ReviewResume.context_summary(summary)

    case Coordination.upsert(coord.task_id, %{
           review_decision: "changes_requested",
           review_last_head_sha: summary.head_sha,
           review_context_summary: context
         }) do
      {:ok, _} ->
        Logger.info(
          "review_resume: changes requested for #{coord.task_id} sha=#{summary.head_sha}"
        )

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "review",
          reason: :review_changes_requested,
          review_decision: "changes_requested"
        })

        broadcast_status(state)
        state

      {:error, reason} ->
        Logger.warning(
          "review_resume: record upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp apply_review_decision(state, coord, summary, :clear) do
    case Coordination.upsert(coord.task_id, %{
           review_decision: "none",
           review_last_head_sha: summary.head_sha || coord.review_last_head_sha,
           review_context_summary: nil
         }) do
      {:ok, _} ->
        Logger.info("review_resume: cleared changes-requested for #{coord.task_id}")

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "review",
          reason: :review_changes_cleared,
          review_decision: "none"
        })

        broadcast_status(state)
        state

      {:error, reason} ->
        Logger.warning(
          "review_resume: clear upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp apply_review_spawn(state, coord, detection) do
    caps = %{
      enabled: review_resume_enabled?(state),
      max_attempts: ci_resume_max_attempts(state)
    }

    case ReviewResume.spawn_evaluate(coord, detection, caps) do
      :noop ->
        state

      :resume ->
        apply_review_resume(state, coord)

      :circuit_open ->
        apply_review_circuit(state, coord)
    end
  end

  defp apply_review_resume(state, coord) do
    case reopen_for_resume(state, coord.task_id) do
      :ok ->
        commit_review_resume(state, coord)

      {:error, reason} ->
        Logger.warning(
          "review_resume: reopen failed for #{coord.task_id}: #{inspect(reason)} (not counting)"
        )

        state
    end
  end

  defp commit_review_resume(state, coord) do
    count = (coord.ci_resume_count || 0) + 1

    case Coordination.upsert(coord.task_id, %{
           ci_resume_count: count,
           ci_circuit_open: false
         }) do
      {:ok, _} ->
        Logger.info("review_resume: re-opened #{coord.task_id} (attempt #{count})")

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "todo",
          reason: :review_resume
        })

        %{
          state
          | completed: MapSet.delete(state.completed, coord.task_id),
            approved_once: MapSet.put(state.approved_once, coord.task_id)
        }

      {:error, reason} ->
        Logger.warning(
          "review_resume: count upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp apply_review_circuit(state, coord) do
    case Coordination.upsert(coord.task_id, %{ci_circuit_open: true}) do
      {:ok, _} ->
        Logger.warning(
          "review_resume: circuit open for #{coord.task_id} (shared resume retries exhausted)"
        )

        Events.broadcast_task_updated(%{
          id: coord.task_id,
          status: "review",
          reason: :ci_circuit
        })

        broadcast_status(state)
        state

      {:error, reason} ->
        Logger.warning(
          "review_resume: circuit upsert failed for #{coord.task_id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp review_resume_enabled?(%{review_resume_caps: %{enabled: true}}), do: true
  defp review_resume_enabled?(_), do: false

  defp ci_resume_max_attempts(%{ci_resume_caps: %{max_attempts: n}})
       when is_integer(n) and n > 0,
       do: n

  defp ci_resume_max_attempts(_), do: 3

  defp handle_run_exit(state, entry, task_id, result) do
    state =
      state
      |> Map.update!(:claimed, &MapSet.delete(&1, task_id))
      |> Map.update!(:last_run_entries, &Map.put(&1, task_id, entry))

    handle_result(state, task_id, result)
  end

  defp spawn_worker(state, task) do
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

  defp handle_result(state, task_id, :ok) do
    case state.tracker.get_issue(state.tracker_config, task_id) do
      {:ok, task} ->
        if task.status in state.terminal_states do
          Logger.info("task #{task_id} succeeded")
          post_run_summary(state, task_id, :ok)
          %{state | completed: MapSet.put(state.completed, task_id)}
        else
          # Runner reported success (exit 0). Do not re-spawn (burns tokens /
          # rate-limits). Force terminal review; retry status patch so GitHub
          # label sticks across process restarts when possible.
          # Retries use send_after — never Process.sleep on this GenServer.
          Logger.warning("task #{task_id} exited ok but status=#{task.status}; forcing review")

          force_terminal_status(state, task_id, "review", 1)
          post_run_summary(state, task_id, :ok)
          %{state | completed: MapSet.put(state.completed, task_id)}
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

  # Best-effort: move tracker to a terminal status after a successful run.
  # Retries via `Process.send_after` so poll ticks / status calls stay responsive.
  # `completed` still skips re-dispatch this boot if the patch never sticks.
  defp force_terminal_status(state, task_id, status, attempt) do
    state.tracker.update_status(state.tracker_config, task_id, status)

    case force_terminal_check(state, task_id) do
      :ok ->
        :ok

      :retry ->
        schedule_force_terminal_retry(task_id, status, attempt)
    end
  end

  defp force_terminal_check(state, task_id) do
    case state.tracker.get_issue(state.tracker_config, task_id) do
      {:ok, t} ->
        if t.status in state.terminal_states, do: :ok, else: :retry

      _ ->
        :retry
    end
  end

  defp schedule_force_terminal_retry(task_id, status, attempt)
       when attempt < @force_terminal_max_attempts do
    delay = @force_terminal_backoff_ms * attempt
    Process.send_after(self(), {:force_terminal_retry, task_id, status, attempt + 1}, delay)
    :ok
  end

  defp schedule_force_terminal_retry(task_id, _status, attempt) do
    Logger.warning(
      "task #{task_id}: status still non-terminal after #{attempt} tries (session skip via completed)"
    )

    :ok
  end

  defp post_run_summary(state, task_id, result) do
    maybe_capture_pr(state, task_id)

    entry = state.last_run_entries[task_id]
    if entry, do: build_and_post(state, task_id, result, entry)
    :ok
  end

  # Best-effort: parse PR URL from run log (agent stdout) into Coordination.
  # Bound to tracker owner/repo when known (confused-deputy guard).
  defp maybe_capture_pr(state, task_id) when is_binary(task_id) do
    log = Svarm.RunLog.get(task_id)
    opts = tracker_repo_opts(state.tracker_config)

    case Coordination.extract_pr_url(log) do
      url when is_binary(url) ->
        case Coordination.record_pr(task_id, url, opts) do
          {:ok, _} ->
            Logger.info("coordination: recorded PR for #{task_id}")

          {:error, :repo_mismatch} ->
            Logger.warning(
              "coordination: ignored PR URL for #{task_id} (owner/repo mismatch tracker)"
            )

          {:error, reason} ->
            Logger.debug("coordination: PR capture failed for #{task_id}: #{inspect(reason)}")
        end

      nil ->
        :ok
    end
  end

  defp tracker_repo_opts(%{owner: owner, repo: repo})
       when is_binary(owner) and is_binary(repo),
       do: [owner: owner, repo: repo]

  defp tracker_repo_opts(_), do: []

  defp build_and_post(state, task_id, result, entry) do
    task = entry.task
    assignee = task.assignee || "default"
    agent = Map.get(state.agents, assignee, %{})
    pr_url = coordination_pr_url(task_id)

    cost = Usage.task_cost(task_id)

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
      cost: cost,
      total_tokens: (cost.prompt_tokens || 0) + (cost.completion_tokens || 0),
      branch: nil,
      pr_url: pr_url,
      exit_code: exit_code_from_result(result)
    }

    state.tracker.post_run_summary(state.tracker_config, task_id, summary)
  end

  defp coordination_pr_url(task_id) do
    case Coordination.get(task_id) do
      %{pr_url: url} when is_binary(url) and url != "" -> url
      _ -> nil
    end
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

  ## retry / backoff

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
      last_tick_mono_ms: state.last_tick_mono_ms,
      budget_caps: state.budget_caps || %{},
      budget_mode: state.budget_mode || :hard,
      last_budget_block: state.last_budget_block,
      ci_resume: state.ci_resume_caps || %{enabled: false},
      review_resume: state.review_resume_caps || %{enabled: false}
    }
  end
end

defimpl Inspect, for: Svarm.Orchestrator do
  @moduledoc false
  # GenServer crash dumps call inspect(state) — never print tokens.

  def inspect(%Svarm.Orchestrator{} = state, opts) do
    data =
      state
      |> Map.from_struct()
      |> Map.update(:tracker_config, %{}, &Svarm.Redact.map/1)
      |> Map.update(:workflow, nil, &redact_workflow/1)
      |> Map.update(:agents, %{}, &redact_agents/1)

    Inspect.Algebra.concat(["%Svarm.Orchestrator", Inspect.Algebra.to_doc(data, opts)])
  end

  defp redact_workflow(%Svarm.Workflow{} = wf) do
    %{path: wf.path, config: Svarm.Redact.map(wf.config || %{})}
  end

  defp redact_workflow(other), do: other

  defp redact_agents(agents) when is_map(agents) do
    Map.new(agents, fn {name, cfg} ->
      cfg =
        cfg
        |> Map.update(:env, %{}, &Svarm.Redact.map/1)
        |> Map.drop([:api_key, "api_key"])

      {name, cfg}
    end)
  end

  defp redact_agents(other), do: other
end
