defmodule Svarm.Orchestrator do
  @moduledoc """
  Orchestrator: Symphony-compatible poll loop. Plain GenServer.

  Tick:     reconcile (stall + tracker state sync §8.5–8.6) → maybe_ci_resume →
            preflight (§6.3) → fetch eligible → dispatch.
  Dispatch: claim → spawn an agent runner task under the Task.Supervisor → monitor.
  Exit:     normal exit → completed (force `review` if tracker still active);
  crash → backoff retry. Multi-turn re-spawn is not used: runners that need
  another turn should return an explicit continue signal in a future revision.
  Retry:    `delay = min(10_000 * 2^(attempt-1), max_retry_backoff_ms)`.

  CI resume (optional): when `ci_resume.enabled`, poll GitHub Checks for managed
  PRs in review and re-open for a fresh agent run with failure context until the
  circuit opens after N attempts. See `Svarm.CiResume`.

  Reconcile now syncs running/claimed tasks against the tracker adapter (external
  terminal states stop workers). Workspace keys use issue source_id per §4.2.

  Issues are fetched via the Svarm.Tracker behaviour, resolved from
  WORKFLOW.md config at boot.
  """
  use GenServer

  require Logger

  alias Svarm.{
    AgentRunner,
    Approval,
    Budget,
    CiResume,
    Coordination,
    Demo,
    Events,
    Settings,
    Tracker,
    Usage,
    Workflow,
    Workspace
  }

  alias Svarm.Tracker.GitHub.Checks

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
  # Bound Checks polls per tick so the GenServer mailbox stays responsive.
  @ci_resume_max_per_tick 3

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
    :last_budget_block,
    active_states: @default_active_states,
    terminal_states: @default_terminal_states,
    running: %{},
    retry_attempts: %{},
    claimed: MapSet.new(),
    completed: MapSet.new(),
    approved_once: MapSet.new(),
    budget_caps: %{},
    ci_resume_caps: %{enabled: false, max_attempts: 3, skip_draft: true},
    last_run_entries: %{},
    last_tick_mono_ms: nil
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
  Reload agents from file+Settings and re-apply workflow/tracker overlay.
  Used by `/setup` Apply — no BEAM restart.
  """
  def reload_config, do: GenServer.call(__MODULE__, :reload_config)

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
    state = maybe_ci_resume(state)
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
    if slots_available?(state) do
      # Same hard caps as first dispatch — retries are still new agent processes
      maybe_budget_or_spawn(state, task)
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

  # Best-effort: exits the worker Task (closes its Port). Does not walk the OS
  # process tree — keep agent.stall_timeout_ms >= PiRPC wall-clock timeout so
  # Svarm.Runner.PiRPC abort→kill_tree runs first on hung sessions.
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
        ci_resume_caps: CiResume.load_caps(nil)
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
        active_states: cfg.active_states,
        terminal_states: cfg.terminal_states,
        tracker_config: Settings.Resolve.tracker_overlay(cfg.tracker_config),
        budget_caps: Budget.load_caps(raw_config),
        ci_resume_caps: CiResume.load_caps(raw_config)
    }
  end

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
    one_shot? = MapSet.member?(state.approved_once, task.id)

    if not one_shot? and Approval.required?(state.approval, task, state.agents) do
      :ok = state.tracker.update_status(state.tracker_config, task.id, Approval.pending_status())
      Logger.info("task #{task.id} held for human approval")
      state
    else
      maybe_budget_or_spawn(state, task)
    end
  end

  defp maybe_budget_or_spawn(state, task) do
    case Budget.check(task.id, state.budget_caps || %{}) do
      :ok ->
        spawn_worker(state, task)

      {:error, :budget_exceeded, meta} ->
        Logger.warning(
          "budget_exceeded task=#{task.id} scope=#{meta.scope} spent=#{meta.spent} cap=#{meta.cap}"
        )

        block = Map.merge(meta, %{task_id: task.id, at: System.system_time(:second)})
        state = %{state | last_budget_block: block}
        broadcast_status(state)
        state
    end
  end

  defp slots_available?(%{running: running, max_concurrent: mc}), do: map_size(running) < mc

  ## CI resume (poll Checks → re-open or open circuit)

  defp maybe_ci_resume(%{ci_resume_caps: %{enabled: true}} = state) do
    # Local tracker has no Checks API. GitHub adapter (or test doubles) may run.
    if state.tracker == Tracker.Local do
      state
    else
      caps = state.ci_resume_caps

      Coordination.list_with_pr(limit: @ci_resume_max_per_tick * 2)
      |> Enum.take(@ci_resume_max_per_tick)
      |> Enum.reduce(state, fn coord, acc ->
        maybe_ci_resume_one(acc, coord, caps)
      end)
    end
  end

  defp maybe_ci_resume(state), do: state

  defp maybe_ci_resume_one(state, coord, caps) do
    task_id = coord.task_id

    cond do
      Map.has_key?(state.running, task_id) or MapSet.member?(state.claimed, task_id) ->
        state

      not pr_matches_tracker?(coord, state.tracker_config) ->
        Logger.debug("ci_resume: skip #{task_id} — PR repo does not match tracker")
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
           skip_draft: caps.skip_draft
         ) do
      {:ok, summary} ->
        apply_ci_decision(state, coord, summary, caps, CiResume.evaluate(coord, summary, caps))

      {:error, reason} ->
        Logger.debug("ci_resume checks error for #{coord.task_id}: #{inspect(reason)}")
        state
    end
  end

  defp apply_ci_decision(state, coord, summary, _caps, :noop) do
    maybe_store_conclusion(coord, summary)
    state
  end

  defp apply_ci_decision(state, _coord, _summary, _caps, :wait), do: state

  defp apply_ci_decision(state, coord, summary, _caps, :resume) do
    # Reopen first; only fingerprint after status is active so a failed
    # reopen cannot burn the head_sha (evaluate would forever :noop).
    case reopen_for_ci_resume(state, coord.task_id) do
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
           ci_context_summary: summary.summary || coord.ci_context_summary
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

  defp reopen_for_ci_resume(state, task_id) do
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
           ci_circuit_open: false
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

  defp maybe_store_conclusion(coord, %{conclusion: conclusion} = summary)
       when conclusion in [:passed, :failed] do
    atom_str = Atom.to_string(conclusion)

    if coord.ci_last_conclusion != atom_str do
      Coordination.upsert(coord.task_id, %{
        ci_last_conclusion: atom_str,
        ci_last_head_sha: summary.head_sha || coord.ci_last_head_sha
      })
    end
  end

  defp maybe_store_conclusion(_coord, _summary), do: :ok

  defp handle_run_exit(state, entry, task_id, result) do
    state =
      state
      |> Map.update!(:claimed, &MapSet.delete(&1, task_id))
      |> Map.update!(:last_run_entries, &Map.put(&1, task_id, entry))

    handle_result(state, task_id, result)
  end

  defp spawn_worker(state, task) do
    # One-shot approval: clear after first spawn attempt (re-gate if agent fails back to todo)
    state = %{state | approved_once: MapSet.delete(state.approved_once, task.id)}

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

    if state.tracker == Tracker.Local do
      :ok
    else
      entry = state.last_run_entries[task_id]
      if entry, do: build_and_post(state, task_id, result, entry)
    end
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

  defp total_tokens_for_task(task_id) do
    Usage.for_task(task_id)
    |> Enum.reduce(0, fn r, acc -> acc + (r.prompt_tokens || 0) + (r.completion_tokens || 0) end)
  end

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
      last_budget_block: state.last_budget_block,
      ci_resume: state.ci_resume_caps || %{enabled: false}
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
