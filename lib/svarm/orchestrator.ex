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

  Cohesive slices live in `Svarm.Orchestrator.{Reconcile, Dispatch, Resume, RunExit}`.
  This module owns GenServer state and `handle_*` callbacks.
  """
  use GenServer

  require Logger

  alias Svarm.{
    AgentQuestion,
    AgentRunner,
    Approval,
    Budget,
    CiResume,
    Demo,
    Events,
    ReviewResume,
    Settings,
    Tracker,
    Workflow,
    Workspace
  }

  alias Svarm.Orchestrator.{Dispatch, Issues, Reconcile, Resume, RunExit, Status}

  alias Svarm.Workflow.Config, as: WorkflowConfig

  @default_poll_interval_ms 30_000
  @default_max_concurrent 3
  @default_stall_timeout_ms 45 * 60_000
  @default_max_retry_backoff_ms 5 * 60_000
  @default_max_retries 5
  @default_active_states ["todo", "in_progress"]
  @default_terminal_states ["done", "failed", "review"]

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
    task_supervisor: Svarm.TaskSup,
    # Tick-scoped id => {:ok, issue} | {:error, reason}. Filled by
    # get_issues/2 during reconcile + depends_on prefetch; not in status/0.
    issue_cache: %{}
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
  crash-retry the same run, then PATCHes the ticket to `todo`.

  Kill-tree runs **before** the tracker PATCH. If `update_status/3` returns
  `{:error, reason}`, the OS tree may already be dead while the tracker
  still shows `in_progress` — callers must not flash Todo.
  """
  @spec abort(String.t()) :: :ok | {:error, :not_running | term()}
  def abort(task_id) when is_binary(task_id) do
    # Kill-tree + worker wait (2s) + tracker patch; keep well under this.
    GenServer.call(__MODULE__, {:abort, task_id}, 15_000)
  end

  @doc false
  defdelegate kill_worker(pid, reason), to: Reconcile

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
      |> Reconcile.sync_tracker()

    send(self(), :tick)
    {:noreply, state}
  end

  ## tick

  @impl true
  def handle_info(:tick, state) do
    state = %{state | issue_cache: %{}}
    state = Reconcile.run(state)
    state = Resume.ci(state)
    state = Resume.review(state)
    state = if Dispatch.valid_preflight?(state), do: Dispatch.run(state), else: state
    state = %{state | last_tick_mono_ms: System.monotonic_time(:millisecond), issue_cache: %{}}
    Process.send_after(self(), :tick, state.poll_interval_ms)
    Status.broadcast(state)
    {:noreply, state}
  end

  ## worker exit (graceful)

  def handle_info({:run_exit, task_id, result}, state) do
    case Map.pop(state.running, task_id) do
      {nil, _running} ->
        {:noreply, state}

      {entry, running} ->
        {:noreply, RunExit.handle(%{state | running: running}, entry, task_id, result)}
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
        state = RunExit.schedule_retry(state, entry.task, {:crash, reason})
        {:noreply, state}
      end
    end
  end

  ## retry timer

  def handle_info({:retry, task_id}, state) do
    {entry, retry_map} = Map.pop(state.retry_attempts, task_id)
    state = %{state | retry_attempts: retry_map}
    {:noreply, RunExit.do_retry(state, entry, task_id)}
  end

  ## force-terminal status patch (non-blocking retries)

  def handle_info({:force_terminal_retry, task_id, status, attempt}, state) do
    RunExit.force_terminal(state, task_id, status, attempt)
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

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Status.summary(state), state}
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

    Status.broadcast(state)
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

        # Snapshot before kill. CLI/PiRPC write failed/review on port death;
        # checking after kill_os_tree would treat a live Abort as a late finish.
        late? = already_terminal?(state, task_id)
        await_worker_exit(entry.pid)

        if late? do
          state = finish_late_abort(state, entry, task_id)
          Status.broadcast(state)
          {:reply, {:error, :not_running}, state}
        else
          apply_abort_todo(state, task_id)
        end
    end
  end

  @impl true
  def handle_cast({:mark_approved, task_id}, state) when is_binary(task_id) do
    {:noreply, %{state | approved_once: MapSet.put(state.approved_once, task_id)}}
  end

  defp drop_worker_monitor(%{mref: mref}) when is_reference(mref) do
    Process.demonitor(mref, [:flush])
  end

  defp drop_worker_monitor(_), do: true

  # Kill the worker first so it cannot write failed/review on port death. The
  # registry entry is still available synchronously, and its monitor reaper is
  # a fallback if the worker exits before lookup.
  defp await_worker_exit(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    AgentRunner.kill_os_tree(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2_000 ->
        Logger.warning("abort: worker #{inspect(pid)} still alive after 2s")
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp apply_abort_todo(state, task_id) do
    case state.tracker.update_status(state.tracker_config, task_id, "todo") do
      :ok ->
        Events.broadcast_agent_line(task_id, "\n[board] aborted\n")
        AgentQuestion.clear(task_id)
        Status.broadcast(state)
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warning(
          "abort: tracker did not move #{task_id} to todo (#{inspect(reason)}); OS tree already stopped"
        )

        AgentQuestion.clear(task_id)
        Status.broadcast(state)
        {:reply, {:error, reason}, state}
    end
  end

  defp already_terminal?(state, task_id) do
    case Issues.get(state.tracker, state.tracker_config, task_id) do
      {:ok, issue} -> issue.status in state.terminal_states
      _ -> false
    end
  end

  defp finish_late_abort(state, entry, task_id) do
    state = Map.update!(state, :last_run_entries, &Map.put(&1, task_id, entry))

    case Issues.get(state.tracker, state.tracker_config, task_id) do
      {:ok, %{status: "failed"}} ->
        # Same as handle_result error: do not session-skip via completed and
        # do not post a run-summary (that is retry-exhaustion only).
        state

      _ ->
        RunExit.post_run_summary(state, task_id, :ok)
        %{state | completed: MapSet.put(state.completed, task_id)}
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
      |> Map.put(:issue_cache, :redacted)

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
