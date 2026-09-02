defmodule Svarm.DispatchGitHubOrchestratorTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Svarm.{Dispatch, Orchestrator}
  alias Svarm.Test.{GitHubIssuesReq, Wait}
  alias Svarm.Tracker.GitHub

  @fake_cli Path.expand("../support/fake_cli_agent.sh", __DIR__)

  @config %{
    owner: "acme",
    repo: "widgets",
    api_key: "t",
    req: GitHubIssuesReq,
    kind: :github,
    active_states: ["todo", "in_progress"],
    terminal_states: ["done", "failed", "review"],
    agent_assignees: ["demo"]
  }

  setup do
    GitHubIssuesReq.reset!()
    original = :sys.get_state(Orchestrator)
    workspace_root = Path.join(System.tmp_dir!(), "svarm_gh_deps_#{:rand.uniform(999_999)}")
    File.mkdir_p!(workspace_root)

    hang_agent = %{
      command: "sh",
      args: [@fake_cli, "hang"],
      env: %{},
      adapter: "cli",
      display_name: "HangDemo",
      name: "demo"
    }

    :sys.replace_state(Orchestrator, fn state ->
      %{
        state
        | tracker: GitHub,
          tracker_config: @config,
          agents: Map.put(state.agents, "demo", hang_agent),
          approval: %{mode: :off, trusted_assignees: MapSet.new()},
          budget_caps: %{},
          budget_mode: :hard,
          workflow: nil,
          workspace_root: workspace_root,
          workspace_isolation: :path,
          max_retries: 5,
          max_retry_backoff_ms: 1,
          max_concurrent: 3,
          ci_resume_caps: %{enabled: false, max_attempts: 3, skip_draft: true},
          review_resume_caps: %{enabled: false},
          running: %{},
          claimed: MapSet.new(),
          completed: MapSet.new(),
          approved_once: MapSet.new(),
          overage_once: MapSet.new(),
          retry_attempts: %{},
          last_run_entries: %{},
          last_budget_block: nil
      }
    end)

    on_exit(fn ->
      if Process.whereis(Orchestrator) do
        running = :sys.get_state(Orchestrator).running

        Enum.each(running, fn {_id, entry} ->
          if is_pid(entry[:pid]) and Process.alive?(entry[:pid]) do
            Svarm.AgentRunner.kill_os_tree(entry[:pid])
            Process.exit(entry[:pid], :kill)
          end
        end)

        :sys.replace_state(Orchestrator, fn state ->
          Enum.each(Map.values(state.retry_attempts), fn
            %{timer: timer} when is_reference(timer) -> Process.cancel_timer(timer)
            _ -> :ok
          end)

          original
        end)
      end

      File.rm_rf(workspace_root)
    end)

    :ok
  end

  test "dependencies_met? blocks GitHub-wired higher priority until dep is terminal" do
    {:ok, %{tasks: created}} =
      Dispatch.run(
        %{
          goal: "gh-orch-deps",
          tasks: [
            %{title: "first", body: "p1", type: "code", priority: 1, assignee: "demo"},
            %{title: "second", body: "p2", type: "code", priority: 2, assignee: "demo"}
          ]
        },
        tracker: GitHub,
        tracker_config: @config
      )

    p1 = Enum.find(created, &(&1.priority == 1))
    p2 = Enum.find(created, &(&1.priority == 2))

    assert {:ok, listed} = GitHub.list_issues(@config)
    p2_listed = Enum.find(listed, &(&1.id == p2.id))
    assert p2_listed.depends_on == [p1.id]

    send(Orchestrator, :tick)

    assert wait_until(fn -> p1.id in Orchestrator.status().running_ids end)
    refute p2.id in Orchestrator.status().running_ids

    assert :ok = GitHub.update_status(@config, p1.id, "done")
    send(Orchestrator, :tick)

    assert wait_until(fn -> p2.id in Orchestrator.status().running_ids end)
    refute p1.id in Orchestrator.status().running_ids
    assert {:ok, %{status: "done"}} = GitHub.get_issue(@config, p1.id)
  end

  defp wait_until(fun, attempts \\ 120) do
    Wait.until(fun, attempts: attempts)
  end
end
