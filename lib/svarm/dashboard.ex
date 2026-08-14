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
  """
  def snapshot do
    tasks = Board.list_tasks()
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
  Per-agent roster: identity, current workload, completed count, running task info.
  Merges agents.toml definitions with live task data.
  """
  def agent_roster(tasks, agents, orchestrator) do
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
        running_started_ms: tallies.running_started_ms
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
