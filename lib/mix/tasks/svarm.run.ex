defmodule Mix.Tasks.Svarm.Run do
  @moduledoc """
  Decompose a goal into tasks via LLM and dispatch them to the kanban board.

  Only starts the database layer — the orchestrator runs separately
  (via `mix phx.server`). Tasks land in the kanban as `todo` and are
  picked up by the orchestrator on its next poll tick.
  """
  use Mix.Task

  @shortdoc "Decompose a goal and dispatch tasks to the kanban board"

  def run(args) do
    # Start only what's needed — immediately stop the orchestrator so
    # tasks are created as 'todo' and picked up by phx.server's poll loop.
    Mix.Task.run("app.start")
    GenServer.stop(Svarm.Orchestrator)

    {opts, remaining, _} =
      OptionParser.parse(args, switches: [research: :string], aliases: [r: :research])

    goal = Enum.join(remaining, " ")
    research = Keyword.get(opts, :research, "")

    if goal == "" do
      Mix.shell().error(~s(Usage: mix svarm.run "your goal here" [--research "context"]))
      System.halt(1)
    end

    Mix.shell().info("Decomposing goal: #{goal}")

    case Svarm.Decompose.run(%{goal: goal, research: research}) do
      {:ok, %{tasks: tasks}} ->
        Mix.shell().info("Decomposed into #{length(tasks)} tasks")
        dispatch_and_report(goal, tasks)

      {:error, reason} ->
        Mix.shell().error("Decompose failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp dispatch_and_report(goal, tasks) do
    case Svarm.Dispatch.run(%{tasks: tasks, goal: goal}) do
      {:ok, %{created_count: count}} ->
        Mix.shell().info("Dispatched #{count} tasks to the board")
        Mix.shell().info("\nTasks created:")
        report_created_issues()

        Mix.shell().info("\nStart the orchestrator to pick these up:")
        Mix.shell().info("  mix phx.server")
        Mix.shell().info("  # then open http://localhost:4000/board")

      {:error, reason} ->
        Mix.shell().error("Dispatch failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp report_created_issues do
    {adapter, config} = Svarm.Tracker.Resolve.adapter_and_config()

    case adapter.list_issues(config, []) do
      {:ok, issues} ->
        Enum.each(issues, fn t ->
          Mix.shell().info("  [#{t.assignee}] (#{t.type}) #{t.title} (#{t.status})")
        end)

      {:error, reason} ->
        Mix.shell().error("Could not list issues: #{inspect(reason)}")
    end
  end
end
