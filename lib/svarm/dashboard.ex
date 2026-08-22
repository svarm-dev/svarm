defmodule Svarm.Dashboard do
  @moduledoc """
  Read API for the operational dashboard. LiveViews call here.

  Answers the team-lead questions: who's doing what, is the queue moving,
  what did it cost. Operates on the same data as Board but aggregates
  differently: per-agent stats, task distribution, and rolling-window cost.
  """
  alias Svarm.{AgentRegistry, AgentRunner, Board, Orchestrator, Usage}

  @doc """
  Full dashboard snapshot. One call gets everything the LiveView needs.

  Returns `{:ok, snapshot}` or `{:error, reason}` when the tracker cannot
  list issues (do not treat that as an idle empty dashboard).
  """
  def snapshot do
    case Board.fetch_tasks() do
      {:ok, tasks} -> {:ok, snapshot_from_tasks(tasks)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_from_tasks(tasks) do
    agents = AgentRunner.load_agents()
    orchestrator = Orchestrator.status()
    # Single session aggregate — derive token totals from the same summary.
    session_cost = Usage.session_cost_summary()

    %{
      tasks: tasks,
      agents: agents,
      orchestrator: orchestrator,
      agent_roster: agent_roster(tasks, agents, orchestrator),
      task_distribution: Board.counts_by_status(tasks),
      human_wait: Board.human_wait_summary(tasks),
      session_cost: session_cost,
      session_totals: Usage.Query.totals_from_summary(session_cost),
      recent_runs: recent_runs(tasks, agents)
    }
  end

  @doc """
  Cost summary for a rolling time window. Accepts "session", "24h", or "7d".
  Rolling 24h / 7d windows use wall-clock `inserted_at` (same honesty as daily
  budget). Monotonic `recorded_at` is not used here — it resets across process
  restarts.
  """
  def cost_for_window("session"), do: Usage.session_cost_summary()

  def cost_for_window(window) when window in ["24h", "7d"] do
    seconds = if window == "24h", do: 86_400, else: 604_800
    since = DateTime.add(DateTime.utc_now(), -seconds, :second)
    Usage.Query.cost_since_inserted_at(since)
  end

  @doc """
  Outcome ROI strip for a spend window (`session` / `24h` / `7d`).

  Uses `Usage.by_outcome/1` (query-time; ledger append-only). Merge rate is
  `merged_tasks / tasks_with_spend` in the window. Cost per merged is
  merged-bucket spend / merged task count (nil when no merges). Estimated
  flag is true when any contributing spend is approximate.
  """
  def roi_for_window(window \\ "session", tasks \\ nil) do
    tasks =
      case tasks do
        list when is_list(list) ->
          list

        _ ->
          case Board.fetch_tasks() do
            {:ok, listed} -> listed
            {:error, _} -> []
          end
      end

    agents = Board.list_agents()
    since = window_since(window)
    statuses = Map.new(tasks, &{&1.id, &1.status})

    overall =
      Usage.by_outcome(task_statuses: statuses, since: since)
      |> metrics_from_outcome()

    by_agent =
      tasks
      |> Enum.group_by(&AgentRegistry.normalize_assignee(&1.assignee))
      |> Enum.map(fn {agent, agent_tasks} ->
        ids = Enum.map(agent_tasks, & &1.id)
        agent_statuses = Map.take(statuses, ids)

        metrics =
          Usage.by_outcome(task_statuses: agent_statuses, since: since, task_ids: ids)
          |> metrics_from_outcome()

        identity = AgentRegistry.identity(agent, agents)

        %{
          assignee: agent,
          display_name: identity.display_name,
          metrics: metrics
        }
      end)
      |> Enum.reject(&(&1.metrics.tasks_with_spend == 0))
      |> Enum.sort_by(& &1.display_name)

    %{
      window: window,
      since: since,
      overall: overall,
      by_agent: by_agent
    }
  end

  defp window_since("session"), do: nil

  defp window_since(window) when window in ["24h", "7d"] do
    seconds = if window == "24h", do: 86_400, else: 604_800
    DateTime.add(DateTime.utc_now(), -seconds, :second)
  end

  defp window_since(_), do: nil

  defp metrics_from_outcome(%{by_outcome: by, task_count: n}) do
    merged = Map.fetch!(by, :merged)
    estimated = Enum.any?([by.merged, by.in_review, by.other], & &1.estimated)

    merge_rate =
      if n > 0 do
        Float.round(merged.task_count / n, 4)
      else
        nil
      end

    cost_per_merged =
      if merged.task_count > 0 do
        Float.round(merged.total_cost_usd / merged.task_count, 4)
      else
        nil
      end

    %{
      merge_rate: merge_rate,
      cost_per_merged_usd: cost_per_merged,
      merged_tasks: merged.task_count,
      in_review_tasks: by.in_review.task_count,
      other_tasks: by.other.task_count,
      tasks_with_spend: n,
      estimated: estimated
    }
  end

  @window_seconds 86_400

  @doc """
  Per-agent roster: identity, current workload, completed count, running task info,
  plus 24h wall-clock cost (from the usage ledger) and retry share when attempts
  are recorded.
  """
  def agent_roster(tasks, agents, orchestrator) do
    cost_by_task =
      DateTime.utc_now()
      |> DateTime.add(-@window_seconds, :second)
      |> Usage.Query.cost_since_by_task()

    active_assignees =
      orchestrator
      |> Map.get(:active_assignees, [])
      |> Enum.map(&AgentRegistry.normalize_assignee/1)

    running_map = Map.get(orchestrator, :running_started, %{})

    agent_keys =
      (Map.keys(agents) ++ Enum.map(tasks, &AgentRegistry.normalize_assignee(&1.assignee)))
      |> Enum.uniq()

    Enum.map(agent_keys, fn key ->
      identity = AgentRegistry.identity(key, agents)
      agent_config = Map.get(agents, key, %{})

      assigned_tasks =
        Enum.filter(tasks, &(AgentRegistry.normalize_assignee(&1.assignee) == key))

      tallies = tally_assigned(assigned_tasks, running_map)
      {window_usd, window_estimated, window_records} = window_cost(assigned_tasks, cost_by_task)

      %{
        key: key,
        display_name: identity.display_name,
        role: identity.role,
        avatar: identity.avatar,
        model: Map.get(agent_config, :model),
        provider: Map.get(agent_config, :provider),
        active_count: tallies.active,
        completed_count: tallies.completed,
        failed_count: tallies.failed,
        total_assigned: length(assigned_tasks),
        busy?: key in active_assignees,
        running_task_id: tallies.running_task && tallies.running_task.id,
        running_task_title: tallies.running_task && tallies.running_task.title,
        running_started_ms: tallies.running_started_ms,
        window_cost_usd: window_usd,
        window_cost_estimated: window_estimated,
        window_record_count: window_records,
        reliability: reliability_rate(assigned_tasks)
      }
    end)
    |> Enum.sort_by(fn a -> {not a.busy?, -a.active_count, -a.total_assigned} end)
  end

  defp tally_assigned(assigned_tasks, running_map) do
    Enum.reduce(
      assigned_tasks,
      %{completed: 0, failed: 0, active: 0, running_task: nil, running_started_ms: nil},
      &tally_task(&1, &2, running_map)
    )
  end

  defp tally_task(task, acc, running_map) do
    acc
    |> bump_status(task.status)
    |> maybe_set_running(task, running_map)
  end

  defp bump_status(acc, status) when status in ["done", "review"],
    do: %{acc | completed: acc.completed + 1}

  defp bump_status(acc, "failed"), do: %{acc | failed: acc.failed + 1}
  defp bump_status(acc, "in_progress"), do: %{acc | active: acc.active + 1}
  defp bump_status(acc, _), do: acc

  defp maybe_set_running(%{running_task: nil} = acc, task, running_map) do
    case Map.get(running_map, task.id) do
      nil -> acc
      ms -> %{acc | running_task: task, running_started_ms: ms}
    end
  end

  defp maybe_set_running(acc, _task, _running_map), do: acc

  defp window_cost(assigned_tasks, cost_by_task) do
    Enum.reduce(assigned_tasks, {0.0, false, 0}, fn task, {usd, estimated, count} ->
      case Map.get(cost_by_task, task.id) do
        %{total_cost_usd: cost, estimated: est, record_count: n} ->
          {usd + cost, estimated or est == true, count + (n || 0)}

        _ ->
          {usd, estimated, count}
      end
    end)
    |> then(fn {usd, estimated, count} -> {Float.round(usd, 2), estimated, count} end)
  end

  # attempts is a retry counter (0 until the first retry). All zeros → n/a
  # (GitHub tracker does not persist attempts).
  defp reliability_rate(tasks) when is_list(tasks) do
    {retried, total} =
      Enum.reduce(tasks, {0, 0}, fn task, {retried, total} ->
        bump = if task_attempts(task) > 0, do: 1, else: 0
        {retried + bump, total + 1}
      end)

    if retried > 0, do: %{retried: retried, total: total}, else: nil
  end

  defp task_attempts(%{attempts: n}) when is_integer(n), do: n
  defp task_attempts(%{"attempts" => n}) when is_integer(n), do: n
  defp task_attempts(_), do: 0

  @doc """
  Last N completed or failed tasks with cost, newest first.
  """
  def recent_runs(tasks, agents, limit \\ 10) do
    recent =
      tasks
      |> Enum.filter(&(&1.status in ["done", "review", "failed"]))
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(limit)

    costs = Usage.task_cost_summaries(Enum.map(recent, & &1.id))

    Enum.map(recent, fn task ->
      cost = Map.get(costs, task.id)
      identity = AgentRegistry.identity(task.assignee, agents)

      %{
        id: task.id,
        title: task.title,
        status: task.status,
        assignee: task.assignee,
        display_name: identity.display_name,
        cost_usd: cost && cost.total_cost_usd,
        estimated: cost && cost.estimated,
        created_at: task.created_at
      }
    end)
  end
end
