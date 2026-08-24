defmodule Svarm.GitHubAttemptsOrchestratorTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Svarm.{Coordination, Issue, KanbanBridge, Orchestrator, Repo}
  alias Svarm.Test.Wait
  alias Svarm.Tracker.GitHub

  @fake_cli Path.expand("../support/fake_cli_agent.sh", __DIR__)
  @node_id "I_gh_attempts"
  @number 42

  defmodule StubReq do
    @table :svarm_github_attempts_stub

    def get(url, _opts) do
      ensure_table!()

      cond do
        String.ends_with?(url, "/comments") ->
          {:ok, %{status: 200, body: []}}

        match?({_n, ""}, Integer.parse(Path.basename(url))) ->
          {:ok, %{status: 200, body: issue()}}

        true ->
          {:ok, %{status: 200, body: [issue()]}}
      end
    end

    def patch(url, opts) do
      ensure_table!()
      json = Keyword.get(opts, :json, %{})

      case Integer.parse(Path.basename(url)) do
        {42, ""} ->
          current = issue()
          labels = patch_labels(json, current)
          state = Map.get(json, :state, current["state"])
          seed(Map.merge(current, %{"labels" => labels, "state" => state}))

        _ ->
          :ok
      end

      {:ok, %{status: 200, body: %{}}}
    end

    def post(_url, _opts), do: {:ok, %{status: 201, body: %{}}}

    def seed(payload) do
      ensure_table!()
      :ets.insert(@table, {:issue, payload})
      :ok
    end

    def issue do
      ensure_table!()

      case :ets.lookup(@table, :issue) do
        [{:issue, payload}] -> payload
        [] -> raise "github attempts stub has no issue"
      end
    end

    def ensure_table! do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end
    end

    defp patch_labels(json, current) do
      case Map.get(json, :labels) do
        list when is_list(list) ->
          Enum.map(list, fn
            label when is_binary(label) -> %{"name" => label}
            %{"name" => _} = label -> label
            other -> %{"name" => to_string(other)}
          end)

        _ ->
          current["labels"]
      end
    end
  end

  setup do
    Repo.delete_all(Coordination)
    KanbanBridge.delete_all_tasks()
    StubReq.ensure_table!()
    StubReq.seed(gh_issue())

    original = :sys.get_state(Orchestrator)
    workspace_root = Path.join(System.tmp_dir!(), "svarm_gh_attempts_#{:rand.uniform(999_999)}")
    File.mkdir_p!(workspace_root)

    fail_agent = %{
      command: "sh",
      args: [@fake_cli, "fail"],
      env: %{},
      adapter: "cli",
      display_name: "FailDemo",
      name: "demo"
    }

    github_config = %{
      kind: :github,
      owner: "acme",
      repo: "widgets",
      api_key: "t",
      req: StubReq,
      active_states: ["todo", "in_progress"],
      terminal_states: ["done", "failed", "review"]
    }

    :sys.replace_state(Orchestrator, fn state ->
      %{
        state
        | tracker: GitHub,
          tracker_config: github_config,
          agents: Map.put(state.agents, "demo", fail_agent),
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

    %{config: github_config}
  end

  test "two GitHub failures increment attempts to 2 via re-fetch", %{config: config} do
    put_running(fetched_issue(config))
    send(Orchestrator, {:run_exit, @node_id, {:error, :agent_exit}})
    flush()

    assert {:ok, after_one} = GitHub.get_issue(config, @node_id)
    # Retry backoff is 1ms; a spawn may already have incremented past 1.
    assert after_one.attempts >= 1
    assert Coordination.get(@node_id).attempts >= 1

    status = Orchestrator.status()
    assert @node_id in status.retry_ids or @node_id in status.running_ids

    drive_second_failure(config)

    assert wait_until(fn ->
             match?({:ok, %{attempts: 2}}, GitHub.get_issue(config, @node_id))
           end)

    assert {:ok, after_two} = GitHub.get_issue(config, @node_id)
    assert after_two.attempts == 2
    assert Coordination.get(@node_id).attempts == 2
  end

  test "N+1 GitHub failures exhaust to failed like Local", %{config: config} do
    :sys.replace_state(Orchestrator, fn state -> %{state | max_retries: 1} end)

    put_running(fetched_issue(config))
    send(Orchestrator, {:run_exit, @node_id, {:error, :agent_exit}})
    flush()

    assert {:ok, %{attempts: 1}} = GitHub.get_issue(config, @node_id)
    drive_second_failure(config)

    assert wait_until(fn ->
             match?({:ok, %{status: "failed"}}, GitHub.get_issue(config, @node_id))
           end)

    assert {:ok, failed} = GitHub.get_issue(config, @node_id)
    assert failed.status == "failed"
    assert failed.attempts == 2
    refute @node_id in Orchestrator.status().retry_ids
  end

  test "Local exhaustion still marks the task failed" do
    task =
      KanbanBridge.create_task(%{
        title: "local exhaust",
        status: "todo",
        assignee: "demo"
      })

    local_config = %{
      kind: :local,
      active_states: ["todo", "in_progress"],
      terminal_states: ["done", "failed", "review"],
      ignored_assignees: []
    }

    :sys.replace_state(Orchestrator, fn state ->
      %{
        state
        | tracker: Svarm.Tracker.Local,
          tracker_config: local_config,
          max_retries: 0,
          running: %{
            task.id => %{
              task: task,
              pid: self(),
              mref: make_ref(),
              run_id: "run_local_exhaust",
              started_mono_ms: System.monotonic_time(:millisecond),
              started_at: System.system_time(:second)
            }
          },
          claimed: MapSet.new([task.id]),
          retry_attempts: %{}
      }
    end)

    send(Orchestrator, {:run_exit, task.id, {:error, :agent_exit}})
    flush()

    assert KanbanBridge.get_task(task.id).status == "failed"
    refute task.id in Orchestrator.status().retry_ids
  end

  defp drive_second_failure(config) do
    # Retry timer is 1ms. Prefer the real spawn; if it already exited, the
    # re-fetch path has already incremented. Only inject a second run_exit
    # when attempts are still 1.
    wait_until(fn ->
      {:ok, issue} = GitHub.get_issue(config, @node_id)

      issue.attempts >= 2 or issue.status == "failed" or
        Map.has_key?(:sys.get_state(Orchestrator).running, @node_id)
    end)

    {:ok, issue} = GitHub.get_issue(config, @node_id)

    cond do
      issue.attempts >= 2 or issue.status == "failed" ->
        :ok

      Map.has_key?(:sys.get_state(Orchestrator).running, @node_id) ->
        wait_until(fn ->
          {:ok, i} = GitHub.get_issue(config, @node_id)
          i.attempts >= 2 or i.status == "failed"
        end)

      true ->
        cancel_retry_timer(@node_id)
        put_running(fetched_issue(config))
        send(Orchestrator, {:run_exit, @node_id, {:error, :agent_exit}})
        flush()
    end
  end

  defp fetched_issue(config) do
    {:ok, issue} = GitHub.get_issue(config, @node_id)
    issue
  end

  defp put_running(%Issue{} = issue) do
    :sys.replace_state(Orchestrator, fn state ->
      running =
        Map.put(state.running, issue.id, %{
          task: issue,
          pid: self(),
          mref: make_ref(),
          run_id: "run_gh_attempts",
          started_mono_ms: System.monotonic_time(:millisecond),
          started_at: System.system_time(:second)
        })

      %{state | running: running, claimed: MapSet.put(state.claimed, issue.id)}
    end)
  end

  defp cancel_retry_timer(task_id) do
    :sys.replace_state(Orchestrator, fn state ->
      case Map.get(state.retry_attempts, task_id) do
        %{timer: timer} when is_reference(timer) ->
          Process.cancel_timer(timer)
          %{state | retry_attempts: Map.delete(state.retry_attempts, task_id)}

        _ ->
          %{state | retry_attempts: Map.delete(state.retry_attempts, task_id)}
      end
    end)
  end

  defp flush, do: (_ = :sys.get_state(Orchestrator)) && :ok

  defp wait_until(fun), do: Wait.until(fun)

  defp gh_issue do
    %{
      "number" => @number,
      "node_id" => @node_id,
      "title" => "retry me",
      "body" => "",
      "labels" => [],
      "assignee" => %{"login" => "demo"},
      "user" => %{"login" => "alice"},
      "created_at" => "2026-01-01T00:00:00Z",
      "repository_url" => "https://api.github.com/repos/acme/widgets",
      "state" => "open"
    }
  end
end
