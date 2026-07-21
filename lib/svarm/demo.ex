defmodule Svarm.Demo do
  @moduledoc """
  Zero-key demo seeding for the live board.

  Used by the Seed demo button, boot-time `SVARM_SEED_DEMO=1`, and tests.
  Creates mock tasks (research → code → docs) that run without API keys.
  """

  @default_goal "Showcase the Svärm orchestrator loop"

  @doc """
  Seed mock demo tasks onto the current board and kick the orchestrator.

  Returns `{:ok, count}` or `{:error, reason}`.
  """
  def seed(goal \\ @default_goal) when is_binary(goal) do
    goal = goal |> String.trim() |> then(fn g -> if g == "", do: @default_goal, else: g end)

    with {:ok, %{tasks: tasks}} <- Svarm.Decompose.run(%{goal: goal, research: ""}, mock: true),
         {:ok, %{created_count: count}} <- Svarm.Dispatch.run(%{tasks: tasks, goal: goal}) do
      # One task at a time: research → code → docs; faster poll between stages
      Application.put_env(:svarm, :orchestrator_max_concurrent, 1)
      Application.put_env(:svarm, :orchestrator_poll_interval_ms, 2_000)

      if pid = Process.whereis(Svarm.Orchestrator) do
        send(pid, {:workflow_reloaded, Svarm.Workflow.Store.get()})
        Svarm.Orchestrator.kick()
      end

      {:ok, count}
    end
  end

  @doc """
  Seed only when the board has no tasks. Used at boot with `SVARM_SEED_DEMO=1`.

  Returns `{:ok, count}`, `:already_has_tasks`, or `{:error, reason}`.
  """
  def seed_if_empty(goal \\ @default_goal) do
    case Svarm.Board.list_tasks() do
      [] -> seed(goal)
      _ -> :already_has_tasks
    end
  rescue
    e in [DBConnection.ConnectionError, ErlangError] ->
      {:error, Exception.message(e)}
  end

  @doc "True when Seed demo routes/UI should be available."
  def routes_enabled? do
    Application.get_env(:svarm, :demo_routes, false) or
      Application.get_env(:svarm, :dev_routes, false)
  end

  @doc false
  def truthy?(nil), do: false
  def truthy?(""), do: false
  def truthy?(v) when v in [true, "1", "true", "TRUE", "yes", "YES", "on", "ON"], do: true
  def truthy?(_), do: false
end
