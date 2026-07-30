defmodule SvarmWeb.DevDemoController do
  @moduledoc false
  use SvarmWeb, :controller

  @default_goal "Showcase the Svärm orchestrator loop"

  def seed(conn, params) do
    goal = params["goal"] |> to_string() |> String.trim()
    goal = if goal == "", do: @default_goal, else: goal

    case Svarm.Demo.seed(goal) do
      {:ok, count} ->
        conn
        |> put_flash(:info, "Cleared board and queued #{count} demo tasks.")
        |> redirect(to: ~p"/board")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Demo seed failed: #{inspect(reason)}")
        |> redirect(to: ~p"/board")
    end
  end
end
