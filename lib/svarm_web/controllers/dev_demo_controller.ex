defmodule SvarmWeb.DevDemoController do
  @moduledoc false
  use SvarmWeb, :controller

  @default_goal "Showcase the Svärm orchestrator loop"

  def seed(conn, params) do
    goal = params["goal"] |> to_string() |> String.trim()
    goal = if goal == "", do: @default_goal, else: goal

    {:ok, %{tasks: tasks}} = Svarm.Decompose.run(%{goal: goal, research: ""}, mock: true)
    {:ok, %{created_count: count}} = Svarm.Dispatch.run(%{tasks: tasks, goal: goal})

    # One task at a time: research → code → docs; faster poll between stages
    Application.put_env(:svarm, :orchestrator_max_concurrent, 1)
    Application.put_env(:svarm, :orchestrator_poll_interval_ms, 2_000)
    send(Svarm.Orchestrator, {:workflow_reloaded, Svarm.Workflow.Store.get()})
    Svarm.Orchestrator.kick()

    conn
    |> put_flash(:info, "Queued #{count} demo tasks on the board.")
    |> redirect(to: ~p"/board")
  end
end
