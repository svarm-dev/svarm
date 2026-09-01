defmodule Svarm.Orchestrator.Reconcile do
  @moduledoc """
  Stall detection and tracker state sync for in-flight orchestrator work.

  Per tick: kill stalled workers, then refresh running/claimed/retrying
  tasks from the tracker adapter. External terminal states (or documented
  gone / `:not_found`) stop the worker and drop the claim. Transient
  tracker errors are logged and left in-flight.
  """

  require Logger

  alias Svarm.AgentRunner
  alias Svarm.Orchestrator.{Issues, RunExit}

  @doc false
  def run(state) do
    state
    |> reconcile_stalls()
    |> sync_tracker()
  end

  @doc false
  def sync_tracker(state) do
    ids =
      (Map.keys(state.running) ++ MapSet.to_list(state.claimed) ++ Map.keys(state.retry_attempts))
      |> Enum.uniq()

    state = Issues.prefetch(state, ids)

    Enum.reduce(ids, state, fn task_id, acc ->
      case Issues.lookup(acc, task_id) do
        {:ok, issue} -> maybe_release_if_terminal(acc, task_id, issue)
        {:error, reason} -> reconcile_get_issue_error(acc, task_id, reason)
      end
    end)
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

        RunExit.schedule_retry(acc, e.task, :stall)
      else
        acc
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
    # An uncatchable exit prevents the runner from interpreting our OS-tree
    # shutdown as an agent failure and overwriting a tracker-terminal status.
    Process.exit(pid, :kill)
    AgentRunner.kill_os_tree(pid)
    Logger.debug("stopped worker #{inspect(pid)}: #{inspect(reason)}")
    true
  end
end
