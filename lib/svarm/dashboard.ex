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
    totals = Usage.Query.session_totals()

    %{
      tasks: tasks,
      agents: agents,
      orchestrator: orchestrator,
      agent_roster: agent_roster(tasks, agents, orchestrator),
      task_distribution: Board.counts_by_status(tasks),
      human_wait: Board.human_wait_summary(tasks),
      session_cost: Usage.session_cost_summary(),
      session_totals: totals,
      recent_runs: recent_runs(tasks, agents)
    }
  end

  @doc """
  Cost summary for a rolling time window. Accepts "session", "24h", or "7d".
  Uses model-specific pricing from Usage.Rates — no flat-rate estimation.
  """
  def cost_for_window("session"), do: Usage.session_cost_summary()

  def cost_for_window(window) when window in ["24h", "7d"] do
    seconds = if window == "24h", do: 86_400, else: 604_800
    since_mono = System.monotonic_time(:millisecond) - seconds * 1000
    Usage.Query.cost_since(since_mono)
  end

  @doc """
  Per-agent roster: identity, current workload, completed count, running task info.
  Merges agents.toml definitions with live task data.
  """
  def agent_roster(tasks, agents, orchestrator) do
    active_assignees = Map.get(orchestrator, :active_assignees, [])
    running_map = Map.get(orchestrator, :running_started, %{})

    agent_keys =
      (Map.keys(agents) ++ Enum.map(tasks, & &1.assignee))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.map(agent_keys, fn key ->
      identity = AgentRegistry.identity(key, agents)
      agent_config = Map.get(agents, key, %{})

      assigned_tasks = Enum.filter(tasks, &(&1.assignee == key))
      completed = Enum.count(assigned_tasks, &(&1.status in ["done", "review"]))
      failed = Enum.count(assigned_tasks, &(&1.status == "failed"))
      active = Enum.count(assigned_tasks, &(&1.status == "in_progress"))

      running_task =
        Enum.find(assigned_tasks, fn t -> Map.has_key?(running_map, t.id) end)

      running_started_ms = running_task && Map.get(running_map, running_task.id)

      %{
        key: key,
        display_name: identity.display_name,
        role: identity.role,
        avatar: identity.avatar,
        model: Map.get(agent_config, :model),
        provider: Map.get(agent_config, :provider),
        active_count: active,
        completed_count: completed,
        failed_count: failed,
        total_assigned: length(assigned_tasks),
        busy?: key in active_assignees,
        running_task_id: running_task && running_task.id,
        running_task_title: running_task && running_task.title,
        running_started_ms: running_started_ms
      }
    end)
    |> Enum.sort_by(fn a -> {not a.busy?, -a.active_count, -a.total_assigned} end)
  end

  @doc """
  Last N completed or failed tasks with cost, newest first.
  """
  def recent_runs(tasks, agents, limit \\ 10) do
    tasks
    |> Enum.filter(&(&1.status in ["done", "review", "failed"]))
    |> Enum.sort_by(& &1.created_at, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn task ->
      cost = Usage.task_cost_summary(task.id)
      identity = AgentRegistry.identity(task.assignee, agents)

      %{
        id: task.id,
        title: task.title,
        status: task.status,
        assignee: task.assignee,
        display_name: identity.display_name,
        cost_usd: cost && cost.total_cost_usd,
        created_at: task.created_at
      }
    end)
  end
end
