defmodule Svarm.Demo do
  @moduledoc """
  Zero-key demo seeding for the live board.

  Used by the Seed demo button, boot-time `SVARM_SEED_DEMO=1`, and tests.
  Creates mock tasks (research → code → docs) that run without API keys.
  Seeds synthetic usage records so the cost receipt shows a real dollar amount.
  """

  @default_goal "Showcase the Svärm orchestrator loop"

  @doc """
  Clear the local board, seed mock demo tasks, and kick the orchestrator.

  Returns `{:ok, count}` or `{:error, reason}`.
  """
  def seed(goal \\ @default_goal) when is_binary(goal) do
    goal = goal |> String.trim() |> then(fn g -> if g == "", do: @default_goal, else: g end)

    # Fresh board each seed — old failed/demo cards should not pile up.
    Svarm.Tracker.Local.delete_all(%{})
    apply_demo_approval_overlay()

    with {:ok, %{tasks: tasks}} <- Svarm.Decompose.run(%{goal: goal, research: ""}, mock: true),
         {:ok, %{created_count: count, tasks: created}} <-
           Svarm.Dispatch.run(%{tasks: tasks, goal: goal}) do
      seed_usage_records(created)
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

  # Demo path always gates code agent; research + docs stay trusted.
  # Survives host WORKFLOW.md that still lists demo_code as trusted or mode: off.
  defp apply_demo_approval_overlay do
    Application.put_env(:svarm, :approval_overlay, %{
      mode: :untrusted,
      trusted_assignees: MapSet.new(["default", "demo_research", "demo_docs"])
    })
  end

  # Seed synthetic usage records for demo tasks so cost receipts show real amounts.
  # Uses gpt-4.1 via openrouter at real market rates — clearly labeled as demo data.
  defp seed_usage_records(tasks) do
    run_id = "demo_run_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    for task <- tasks do
      # Realistic token counts for a coding task
      prompt_tokens = Enum.random(800..2500)
      completion_tokens = Enum.random(200..900)

      Svarm.Usage.Ledger.append(%{
        run_id: run_id,
        task_id: task_id(task),
        tenant: "demo",
        source: "worker",
        provider: "openrouter",
        model_id: "gpt-4.1",
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        estimated: true
      })
    end
  end

  defp task_id(%{id: id}), do: id
  defp task_id(%{"id" => id}), do: id
  defp task_id(_), do: "unknown"
end
