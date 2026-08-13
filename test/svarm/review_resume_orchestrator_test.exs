defmodule Svarm.ReviewResumeOrchestratorTest do
  use ExUnit.Case, async: false

  alias Svarm.{Coordination, KanbanBridge, Orchestrator, Repo}
  alias Svarm.Test.Wait

  defp flush_orchestrator do
    _ = :sys.get_state(Orchestrator)
    :ok
  end

  defp wait_until(fun, opts \\ []) do
    Wait.until(fun, opts)
  end

  defmodule StubReviews do
    def summarize_pr_reviews(_o, _r, _n, _config, _opts \\ []) do
      Application.get_env(:svarm, :review_resume_test_result) ||
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

    def get_issue(_config, id) do
      issues = Application.get_env(:svarm, :review_resume_test_issues, %{})

      case Map.fetch(issues, id) do
        {:ok, issue} -> {:ok, issue}
        :error -> {:error, :not_found}
      end
    end

    def update_status(_config, id, status) do
      issues = Application.get_env(:svarm, :review_resume_test_issues, %{})

      case Map.fetch(issues, id) do
        {:ok, issue} ->
          Application.put_env(
            :svarm,
            :review_resume_test_issues,
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

  setup do
    KanbanBridge.delete_all_tasks()
    Repo.delete_all(Coordination)

    original = :sys.get_state(Orchestrator)
    prev_mod = Application.get_env(:svarm, :github_reviews_module)
    Application.put_env(:svarm, :github_reviews_module, StubReviews)
    Application.put_env(:svarm, :review_resume_test_issues, %{})
    Application.put_env(:svarm, :review_resume_test_result, nil)

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
          ci_resume_caps: %{enabled: false, max_attempts: 3, skip_draft: true}
      }
    end)

    on_exit(fn ->
      if prev_mod do
        Application.put_env(:svarm, :github_reviews_module, prev_mod)
      else
        Application.delete_env(:svarm, :github_reviews_module)
      end

      Application.delete_env(:svarm, :review_resume_test_issues)
      Application.delete_env(:svarm, :review_resume_test_result)

      if Process.whereis(Orchestrator) do
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end)

    :ok
  end

  defp put_issue(task_id, status \\ "review") do
    issues = Application.get_env(:svarm, :review_resume_test_issues, %{})

    Application.put_env(
      :svarm,
      :review_resume_test_issues,
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
    Application.get_env(:svarm, :review_resume_test_issues, %{}) |> Map.get(task_id)
  end

  test "records changes requested without reopening the ticket" do
    task_id = "review_resume_1"
    put_issue(task_id)

    {:ok, _} =
      Coordination.upsert(task_id, %{
        pr_url: "https://github.com/o/r/pull/1",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 1
      })

    Application.put_env(
      :svarm,
      :review_resume_test_result,
      {:ok,
       %{
         decision: :changes_requested,
         head_sha: "sha_a",
         reviewer_logins: ["alice"],
         summary: "Changes requested by alice",
         draft: false,
         review_count: 1
       }}
    )

    send(Orchestrator, :tick)

    assert wait_until(fn ->
             match?(%{review_decision: "changes_requested"}, Coordination.get(task_id))
           end)

    coord = Coordination.get(task_id)
    assert coord.review_decision == "changes_requested"
    assert coord.review_last_head_sha == "sha_a"
    assert coord.review_context_summary =~ "alice"
    assert get_issue(task_id).status == "review"

    # Same sha on next tick: no extra write churn (fingerprint holds)
    send(Orchestrator, :tick)
    flush_orchestrator()
    assert Coordination.get(task_id).review_decision == "changes_requested"
    assert get_issue(task_id).status == "review"
  end

  test "clears recorded state when reviews are no longer changes requested" do
    task_id = "review_resume_clear"
    put_issue(task_id)

    {:ok, _} =
      Coordination.upsert(task_id, %{
        pr_url: "https://github.com/o/r/pull/2",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 2,
        review_decision: "changes_requested",
        review_last_head_sha: "sha_a"
      })

    Application.put_env(
      :svarm,
      :review_resume_test_result,
      {:ok,
       %{
         decision: :none,
         head_sha: "sha_a",
         reviewer_logins: [],
         summary: "no changes requested",
         draft: false,
         review_count: 1
       }}
    )

    send(Orchestrator, :tick)

    assert wait_until(fn ->
             match?(%{review_decision: "none"}, Coordination.get(task_id))
           end)

    assert get_issue(task_id).status == "review"
  end

  test "does not record when ticket is not in review" do
    task_id = "review_resume_todo"
    put_issue(task_id, "todo")

    {:ok, _} =
      Coordination.upsert(task_id, %{
        pr_url: "https://github.com/o/r/pull/3",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 3
      })

    Application.put_env(
      :svarm,
      :review_resume_test_result,
      {:ok,
       %{
         decision: :changes_requested,
         head_sha: "z",
         reviewer_logins: ["x"],
         summary: "x",
         draft: false,
         review_count: 1
       }}
    )

    send(Orchestrator, :tick)
    flush_orchestrator()

    assert Coordination.get(task_id).review_decision == nil
    assert get_issue(task_id).status == "todo"
  end
end
