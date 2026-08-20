defmodule Mix.Tasks.Svarm.Demo do
  @moduledoc """
  End-to-end demo: mock decompose, seed board, watch orchestrator.

  Uses a temporary SQLite database and workspace root so it runs in isolation
  from the phx.server board. No API keys needed — everything is mocked.
  """
  use Mix.Task

  @shortdoc "End-to-end demo: mock decompose, seed board, watch orchestrator (no API keys)"

  @default_goal "Showcase the Svärm orchestrator loop"
  @watch_timeout_ms 90_000
  @poll_interval_ms 500

  def run(args) do
    {opts, remaining, _} =
      OptionParser.parse(args,
        switches: [watch: :boolean, no_watch: :boolean, research: :string],
        aliases: [r: :research]
      )

    goal = remaining |> Enum.join(" ") |> String.trim()
    goal = if goal == "", do: @default_goal, else: goal
    research = Keyword.get(opts, :research, "")
    watch? = Keyword.get(opts, :watch, true) and not Keyword.get(opts, :no_watch, false)

    root = Path.join(System.tmp_dir!(), "svarm_demo_#{System.system_time(:millisecond)}")
    File.mkdir_p!(root)

    db_path = Path.join(root, "kanban.db")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(workspace_root)

    Application.put_env(:svarm, Svarm.Repo, database: db_path)
    Application.put_env(:svarm, :orchestrator_poll_interval_ms, @poll_interval_ms)
    Application.put_env(:svarm, :orchestrator_workspace_root, workspace_root)
    Application.put_env(:svarm, :orchestrator_max_concurrent, 1)

    Mix.Task.run("app.start")

    shell = Mix.shell()

    shell.info("""
    Svärm demo (isolated DB)
      kanban:    #{db_path}
      workspaces: #{workspace_root}
    """)

    shell.info("Decomposing (mock LLM): #{goal}")

    {:ok, %{tasks: tasks}} = Svarm.Decompose.run(%{goal: goal, research: research}, mock: true)
    shell.info("→ #{length(tasks)} tasks")

    {:ok, %{created_count: count}} = Svarm.Dispatch.run(%{tasks: tasks, goal: goal})
    shell.info("Dispatched #{count} tasks. Orchestrator poll every #{@poll_interval_ms}ms.\n")

    print_board(shell)

    if watch? do
      shell.info(
        "Watching board until tasks finish or #{div(@watch_timeout_ms, 1000)}s timeout…\n"
      )

      watch_until_done(shell, @watch_timeout_ms)
    else
      Svarm.Orchestrator.kick()
      shell.info("Single orchestrator kick (--no-watch). Re-run with default to watch live.")
    end

    shell.info("\nOrchestrator: #{inspect(Svarm.Orchestrator.status())}")
    shell.info("Demo data under #{root} (delete when done).")

    shell.info("""

    Note: this Mix task is a separate BEAM process from `mix phx.server`.
    /board on the server uses ~/.svarm/kanban/kanban.db — not this tmp DB.

    With phx.server running, seed the live board instead:
      curl -X POST "http://localhost:4000/dev/demo/seed?goal=create+a+cool+app"
    Or open POST from /board (dev "Seed demo" button).
    """)
  end

  @watch_interval_ms 1_000

  defp watch_until_done(shell, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    terminal = terminal_states()

    stream =
      Stream.repeatedly(fn ->
        Process.sleep(@watch_interval_ms)
        :ok
      end)

    result =
      Enum.reduce_while(stream, :watching, fn _, _ ->
        print_board(shell)
        check_board_state(terminal, deadline)
      end)

    case result do
      :done -> shell.info("All tasks reached a terminal state.")
      :timeout -> shell.info("Timeout — some tasks may still be active.")
    end
  end

  defp check_board_state(terminal, deadline) do
    if board_settled?(terminal) do
      {:halt, :done}
    else
      check_timeout(deadline)
    end
  end

  defp check_timeout(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:halt, :timeout}
    else
      {:cont, :watching}
    end
  end

  defp terminal_states do
    case Svarm.Workflow.Store.get() do
      %Svarm.Workflow{} = wf -> Svarm.Workflow.Config.from(wf).terminal_states
      _ -> ["done", "failed", "review"]
    end
  end

  defp board_settled?(terminal) do
    {:ok, tasks} = list_issues()

    tasks != [] and Enum.all?(tasks, fn t -> t.status in terminal end)
  end

  defp print_board(shell) do
    {:ok, issues} = list_issues()

    Enum.each(issues, fn t ->
      shell.info("  #{String.pad_trailing(t.status, 14)} [#{t.assignee}] #{t.title}")
    end)
  end

  defp list_issues do
    {adapter, config} = Svarm.Tracker.Resolve.adapter_and_config()
    adapter.list_issues(config, [])
  end
end
