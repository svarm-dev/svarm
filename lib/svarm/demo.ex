defmodule Svarm.Demo do
  @moduledoc """
  Zero-key demo seeding for the live board.

  Used by the Seed demo button, boot-time `SVARM_SEED_DEMO=1`, and tests.
  Creates mock tasks (research → code → docs) that run without API keys.
  Seeds synthetic usage records so the cost receipt shows a real dollar amount.

  ## Approval overlay lifetime

  Seed applies a process-global `:approval_overlay` so the demo always gates
  `demo_code` even if WORKFLOW.md still trusts all demo agents. Overlay trusts
  only `demo_research` and `demo_docs` (not `default`). The overlay is only
  merged by the orchestrator when a demo profile flag is active
  (`seed_demo_on_boot`, `demo_routes`, or `dev_routes`), and never weakens a
  WORKFLOW `mode: all` base. Non-demo boots clear any leftover overlay.
  """

  alias Svarm.{KanbanBridge, Tracker}

  @default_goal "Showcase the Svärm orchestrator loop"

  @doc """
  Clear the local board, seed mock demo tasks, and kick the orchestrator.

  Refuses when the active tracker is GitHub or the local board already has
  non-demo assignees (avoids wiping real work). Blank/nil assignees count as
  non-demo.

  Order: preflight → approval overlay + sync Orchestrator reload → Decompose
  (no board mutation) → wipe board → Dispatch → kick. If Decompose fails the
  previous board is left intact. Dispatch failure after wipe can leave an empty
  board (acceptable residual for local wipe).

  Returns `{:ok, count}` or `{:error, reason}`.
  """
  def seed(goal \\ @default_goal) when is_binary(goal) do
    goal = goal |> String.trim() |> then(fn g -> if g == "", do: @default_goal, else: g end)

    with :ok <- preflight_seed(),
         :ok <- prepare_approval_overlay(),
         {:ok, %{tasks: tasks}} <- Svarm.Decompose.run(%{goal: goal, research: ""}, mock: true),
         # Wipe only after decompose succeeds so a mock failure leaves the board.
         :ok <- wipe_local_board(),
         {:ok, %{created_count: count, tasks: created}} <-
           Svarm.Dispatch.run(%{tasks: tasks, goal: goal}) do
      finalize_seed(created)
      {:ok, count}
    end
  end

  @doc """
  Seed only when the board has no tasks. Used at boot with `SVARM_SEED_DEMO=1`.

  Returns `{:ok, count}`, `:already_has_tasks`, or `{:error, reason}`.
  """
  def seed_if_empty(goal \\ @default_goal) do
    with :ok <- preflight_seed() do
      case Svarm.Board.fetch_tasks() do
        {:ok, []} -> seed(goal)
        {:ok, _} -> :already_has_tasks
        {:error, reason} -> {:error, reason}
      end
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

  @doc """
  True when demo profile knobs allow merging `:approval_overlay`.

  Active when any of `seed_demo_on_boot`, `demo_routes`, or `dev_routes` is set.
  """
  def demo_profile_active? do
    Application.get_env(:svarm, :seed_demo_on_boot, false) or
      Application.get_env(:svarm, :demo_routes, false) or
      Application.get_env(:svarm, :dev_routes, false)
  end

  @doc """
  Force demo approval policy: `mode: untrusted`, trust `demo_research` /
  `demo_docs` only (not `default` or `demo_code`).

  Called by seed so the approval chip is visible even if WORKFLOW.md is outdated.
  """
  def apply_approval_overlay do
    Application.put_env(:svarm, :approval_overlay, %{
      mode: :untrusted,
      trusted_assignees: MapSet.new(["demo_research", "demo_docs"])
    })
  end

  @doc "Remove process-global demo approval overlay (non-demo boots)."
  def clear_approval_overlay do
    Application.delete_env(:svarm, :approval_overlay)
  end

  @doc "User-facing flash message for demo seed failures."
  def flash_error(:github_tracker),
    do: "Demo seed refused: active tracker is GitHub. Switch to local tracker first."

  def flash_error(:non_demo_tasks),
    do: "Demo seed refused: board has non-demo tasks. Clear them or use only demo_* assignees."

  def flash_error(other), do: "Demo seed failed: #{inspect(other)}"

  @doc false
  def truthy?(nil), do: false
  def truthy?(""), do: false
  def truthy?(v) when v in [true, "1", "true", "TRUE", "yes", "YES", "on", "ON"], do: true
  def truthy?(_), do: false

  defp preflight_seed do
    {adapter, _config} = Tracker.Resolve.adapter_and_config()

    if Tracker.Resolve.supports?(adapter, :connectivity_probe) do
      {:error, :github_tracker}
    else
      check_non_demo_tasks()
    end
  end

  defp check_non_demo_tasks do
    tasks = KanbanBridge.list_tasks([])

    if Enum.any?(tasks, &non_demo_assignee?/1) do
      {:error, :non_demo_tasks}
    else
      :ok
    end
  end

  defp non_demo_assignee?(%{assignee: name}) when is_binary(name) and name != "" do
    not String.starts_with?(name, "demo_")
  end

  defp non_demo_assignee?(%{assignee: name}) when name in [nil, ""], do: true
  defp non_demo_assignee?(%{}), do: true
  defp non_demo_assignee?(_), do: true

  defp prepare_approval_overlay do
    apply_approval_overlay()
    sync_orchestrator_approval()
    :ok
  end

  # Sync overlay into Orchestrator state before any new todos exist (reload_config
  # re-runs put_approval_config). No-op when Orchestrator is not started.
  defp sync_orchestrator_approval do
    if Process.whereis(Svarm.Orchestrator) do
      _ = Svarm.Orchestrator.reload_config()
    end

    :ok
  end

  defp wipe_local_board do
    {adapter, config} = Tracker.Resolve.adapter_and_config()
    adapter.delete_all(config)
    :ok
  end

  defp finalize_seed(created) do
    seed_usage_records(created)
    # One task at a time: research → code → docs; faster poll between stages
    Application.put_env(:svarm, :orchestrator_max_concurrent, 1)
    Application.put_env(:svarm, :orchestrator_poll_interval_ms, 2_000)

    if Process.whereis(Svarm.Orchestrator) do
      Svarm.Orchestrator.kick()
    end

    :ok
  end

  # Seed synthetic usage records for demo tasks so cost receipts show real amounts.
  # Uses gpt-4.1 via openrouter at real market rates — clearly labeled as demo data.
  defp seed_usage_records(tasks) do
    run_id = "demo_run_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    for task <- tasks do
      # Realistic token counts for a coding task
      prompt_tokens = Enum.random(800..2500)
      completion_tokens = Enum.random(200..900)

      Svarm.Usage.append(
        run_id: run_id,
        task_id: task_id(task),
        tenant: "demo",
        source: "worker",
        provider: "openrouter",
        model_id: "gpt-4.1",
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        estimated: true
      )
    end
  end

  defp task_id(%{id: id}), do: id
  defp task_id(%{"id" => id}), do: id
  defp task_id(_), do: "unknown"
end
