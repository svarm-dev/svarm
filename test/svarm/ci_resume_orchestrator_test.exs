defmodule Svarm.CiResumeOrchestratorTest do
  use ExUnit.Case, async: false

  alias Svarm.{Coordination, KanbanBridge, Orchestrator, Repo}
  alias Svarm.Test.Wait

  # Barrier: wait until prior orchestrator mailbox messages finish.
  defp flush_orchestrator do
    _ = :sys.get_state(Orchestrator)
    :ok
  end

  defp wait_until(fun, opts \\ []) do
    Wait.until(fun, opts)
  end

  defmodule StubChecks do
    def summarize_pr_checks(_o, _r, _n, _config, _opts \\ []) do
      Application.get_env(:svarm, :ci_resume_test_checks_result) ||
        {:ok,
         %{
           conclusion: :passed,
           head_sha: "x",
           failed_names: [],
           summary: "ok",
           draft: false,
           check_count: 0
         }}
    end
  end

  defmodule StubReviewsNone do
    def summarize_pr_reviews(_o, _r, _n, _config, _opts \\ []) do
      {:ok,
       %{
         decision: :none,
         head_sha: "x",
         reviewer_logins: [],
         summary: "no changes requested",
         draft: false,
         review_count: 0
       }}
    end
  end

  defmodule ReviewTracker do
    def list_eligible(_config), do: {:ok, []}

    def list_issues(_config, filters \\ []) do
      issues = Application.get_env(:svarm, :ci_resume_test_issues, %{}) |> Map.values()
      status = Keyword.get(filters, :status)
      issues = if status, do: Enum.filter(issues, &(&1.status == status)), else: issues
      {:ok, issues}
    end

    def get_issue(_config, id) do
      issues = Application.get_env(:svarm, :ci_resume_test_issues, %{})

      case Map.fetch(issues, id) do
        {:ok, issue} -> {:ok, issue}
        :error -> {:error, :not_found}
      end
    end

    def update_status(_config, id, status) do
      issues = Application.get_env(:svarm, :ci_resume_test_issues, %{})

      case Map.fetch(issues, id) do
        {:ok, issue} ->
          Application.put_env(
            :svarm,
            :ci_resume_test_issues,
            Map.put(issues, id, %{issue | status: status})
          )

          :ok

        :error ->
          :ok
      end
    end

    def update_attempts(_config, _id, _n), do: :ok
    def post_run_summary(_config, _id, _summary), do: :ok
  end

  # Simulates old GitHub bug: update_status("todo") leaves status as review
  defmodule StickyReviewTracker do
    def list_eligible(_config), do: {:ok, []}

    def list_issues(_config, filters \\ []) do
      issues = Application.get_env(:svarm, :ci_resume_test_issues, %{}) |> Map.values()
      status = Keyword.get(filters, :status)
      issues = if status, do: Enum.filter(issues, &(&1.status == status)), else: issues
      {:ok, issues}
    end

    def get_issue(_config, id) do
      issues = Application.get_env(:svarm, :ci_resume_test_issues, %{})

      case Map.fetch(issues, id) do
        {:ok, issue} -> {:ok, issue}
        :error -> {:error, :not_found}
      end
    end

    def update_status(_config, _id, _status), do: :ok
    def update_attempts(_config, _id, _n), do: :ok
    def post_run_summary(_config, _id, _summary), do: :ok
  end

  setup do
    KanbanBridge.delete_all_tasks()
    Repo.delete_all(Coordination)

    original = :sys.get_state(Orchestrator)
    prev_checks = Application.get_env(:svarm, :github_checks_module)
    prev_reviews = Application.get_env(:svarm, :github_reviews_module)
    Application.put_env(:svarm, :github_checks_module, StubChecks)
    Application.put_env(:svarm, :github_reviews_module, StubReviewsNone)
    Application.put_env(:svarm, :ci_resume_test_issues, %{})
    Application.put_env(:svarm, :ci_resume_test_checks_result, nil)

    :sys.replace_state(Orchestrator, fn state ->
      %{
        state
        | running: %{},
          claimed: MapSet.new(),
          completed: MapSet.new(),
          approved_once: MapSet.new(),
          retry_attempts: %{},
          last_budget_block: nil,
          last_run_entries: %{},
          tracker: ReviewTracker,
          tracker_config: %{
            kind: :github,
            owner: "o",
            repo: "r",
            api_key: "test-token",
            active_states: ["todo", "in_progress"],
            terminal_states: ["done", "failed", "review"]
          },
          ci_resume_caps: %{enabled: true, max_attempts: 2, skip_draft: true}
      }
    end)

    on_exit(fn ->
      if prev_checks do
        Application.put_env(:svarm, :github_checks_module, prev_checks)
      else
        Application.delete_env(:svarm, :github_checks_module)
      end

      if prev_reviews do
        Application.put_env(:svarm, :github_reviews_module, prev_reviews)
      else
        Application.delete_env(:svarm, :github_reviews_module)
      end

      Application.delete_env(:svarm, :ci_resume_test_issues)
      Application.delete_env(:svarm, :ci_resume_test_checks_result)

      if Process.whereis(Orchestrator) do
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end)

    :ok
  end

  defp put_issue(task_id, status \\ "review") do
    issues = Application.get_env(:svarm, :ci_resume_test_issues, %{})

    Application.put_env(
      :svarm,
      :ci_resume_test_issues,
      Map.put(issues, task_id, %{
        id: task_id,
        title: "x",
        status: status,
        assignee: "cody",
        attempts: 0,
        body: ""
      })
    )
  end

  defp get_issue(task_id) do
    Application.get_env(:svarm, :ci_resume_test_issues, %{}) |> Map.get(task_id)
  end

  test "resume reopens todo, increments count, fingerprints sha" do
    task_id = "ci_resume_1"
    put_issue(task_id)

    {:ok, _} =
      Coordination.upsert(task_id, %{
        pr_url: "https://github.com/o/r/pull/1",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 1,
        ci_resume_count: 0
      })

    Application.put_env(
      :svarm,
      :ci_resume_test_checks_result,
      {:ok,
       %{
         conclusion: :failed,
         head_sha: "sha_a",
         failed_names: ["mix"],
         summary: "CI failed: mix",
         draft: false,
         check_count: 1
       }}
    )

    :sys.replace_state(Orchestrator, fn state ->
      %{state | completed: MapSet.put(state.completed, task_id)}
    end)

    send(Orchestrator, :tick)

    assert wait_until(fn ->
             match?(%{ci_resume_count: 1}, Coordination.get(task_id))
           end)

    coord = Coordination.get(task_id)
    assert coord.ci_resume_count == 1
    assert coord.ci_last_head_sha == "sha_a"
    assert is_binary(coord.ci_context_summary)
    assert coord.ci_context_summary =~ "mix"

    assert get_issue(task_id).status == "todo"

    state = :sys.get_state(Orchestrator)
    refute MapSet.member?(state.completed, task_id)
    # CI resume skips first-run approval re-gate on the next dispatch
    assert MapSet.member?(state.approved_once, task_id)

    # Same sha on next tick: no second resume
    send(Orchestrator, :tick)
    flush_orchestrator()
    assert Coordination.get(task_id).ci_resume_count == 1
  end

  test "circuit opens after max_attempts resumes" do
    task_id = "ci_circuit_1"
    put_issue(task_id)

    {:ok, _} =
      Coordination.upsert(task_id, %{
        pr_url: "https://github.com/o/r/pull/2",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 2,
        ci_resume_count: 2,
        ci_last_head_sha: "old"
      })

    Application.put_env(
      :svarm,
      :ci_resume_test_checks_result,
      {:ok,
       %{
         conclusion: :failed,
         head_sha: "sha_new",
         failed_names: ["ci"],
         summary: "failed",
         draft: false,
         check_count: 1
       }}
    )

    send(Orchestrator, :tick)

    assert wait_until(fn ->
             match?(%{ci_circuit_open: true}, Coordination.get(task_id))
           end)

    coord = Coordination.get(task_id)
    assert coord.ci_circuit_open == true
    # Still review — not failed theater
    assert get_issue(task_id).status == "review"
  end

  test "failed reopen does not fingerprint head_sha" do
    task_id = "ci_reopen_fail"
    put_issue(task_id)

    {:ok, _} =
      Coordination.upsert(task_id, %{
        pr_url: "https://github.com/o/r/pull/4",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 4,
        ci_resume_count: 0
      })

    Application.put_env(
      :svarm,
      :ci_resume_test_checks_result,
      {:ok,
       %{
         conclusion: :failed,
         head_sha: "sha_sticky",
         failed_names: ["x"],
         summary: "x",
         draft: false,
         check_count: 1
       }}
    )

    :sys.replace_state(Orchestrator, fn state ->
      %{state | tracker: StickyReviewTracker}
    end)

    send(Orchestrator, :tick)
    flush_orchestrator()

    coord = Coordination.get(task_id)
    assert coord.ci_resume_count == 0
    assert coord.ci_last_head_sha == nil
    assert get_issue(task_id).status == "review"
  end

  test "disabled caps are no-op" do
    task_id = "ci_off_1"
    put_issue(task_id)

    {:ok, _} =
      Coordination.upsert(task_id, %{
        pr_url: "https://github.com/o/r/pull/3",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 3
      })

    Application.put_env(
      :svarm,
      :ci_resume_test_checks_result,
      {:ok,
       %{
         conclusion: :failed,
         head_sha: "z",
         failed_names: ["x"],
         summary: "x",
         draft: false,
         check_count: 1
       }}
    )

    :sys.replace_state(Orchestrator, fn state ->
      %{state | ci_resume_caps: %{enabled: false, max_attempts: 3, skip_draft: true}}
    end)

    send(Orchestrator, :tick)
    flush_orchestrator()

    assert Coordination.get(task_id).ci_resume_count == 0
    assert get_issue(task_id).status == "review"
  end
end
