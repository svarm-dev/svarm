defmodule Svarm.Usage.OutcomesTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Svarm.{Coordination, KanbanBridge, Usage}
  alias Svarm.Repo
  alias Svarm.Usage.Record

  @github_config %{kind: :github, owner: "acme", repo: "app", api_key: "t"}

  defmodule StubReq do
    def get(url, _opts) do
      case Process.get(:github_pr_merged) do
        :merged ->
          {:ok, %{status: 200, body: %{"merged" => true, "state" => "closed"}}}

        :closed_unmerged ->
          {:ok, %{status: 200, body: %{"merged" => false, "state" => "closed"}}}

        :http_error ->
          {:ok, %{status: 500, body: %{}}}

        :network ->
          {:error, :timeout}

        :flunk ->
          flunk("unexpected GitHub call #{url}")

        other ->
          flunk("unexpected stub #{inspect(other)} for #{url}")
      end
    end
  end

  setup do
    KanbanBridge.delete_all_tasks()
    Repo.delete_all(Record)
    Repo.delete_all(Coordination)
    :ok
  end

  test "classify_status buckets" do
    assert Usage.classify_outcome_status("done") == :merged
    assert Usage.classify_outcome_status("review") == :in_review
    assert Usage.classify_outcome_status("todo") == :other
    assert Usage.classify_outcome_status(nil) == :other
    assert Usage.outcome_buckets() == [:merged, :in_review, :other]
  end

  test "by_outcome attributes mixed statuses and flags estimates" do
    done = KanbanBridge.create_task(%{title: "done", status: "done", assignee: "demo"})
    review = KanbanBridge.create_task(%{title: "review", status: "review", assignee: "demo"})
    todo = KanbanBridge.create_task(%{title: "todo", status: "todo", assignee: "demo"})

    Usage.append(
      run_id: "run_m",
      task_id: done.id,
      source: "agent",
      provider: "openrouter",
      model_id: "test/m",
      prompt_tokens: 100,
      completion_tokens: 50,
      estimated: true
    )

    Usage.append(
      run_id: "run_r",
      task_id: review.id,
      source: "agent",
      provider: "openrouter",
      model_id: "test/m",
      prompt_tokens: 20,
      completion_tokens: 10,
      estimated: true
    )

    Usage.append(
      run_id: "run_o",
      task_id: todo.id,
      source: "agent",
      provider: "openrouter",
      model_id: "test/m",
      prompt_tokens: 5,
      completion_tokens: 5,
      estimated: true
    )

    statuses = %{
      done.id => "done",
      review.id => "review",
      todo.id => "todo"
    }

    result = Usage.by_outcome(task_statuses: statuses)

    assert result.task_count == 3
    assert result.by_outcome.merged.task_count == 1
    assert result.by_outcome.in_review.task_count == 1
    assert result.by_outcome.other.task_count == 1

    assert result.by_outcome.merged.record_count >= 1
    assert result.by_outcome.merged.estimated == true
    assert result.by_outcome.merged.total_cost_usd >= 0.0

    assert result.by_outcome.in_review.estimated == true
    assert result.by_outcome.other.estimated == true
  end

  test "unknown task ids land in other" do
    Usage.append(
      run_id: "run_ghost",
      task_id: "ghost_task",
      source: "agent",
      provider: "openrouter",
      model_id: "test/m",
      prompt_tokens: 1,
      completion_tokens: 1,
      estimated: true
    )

    result = Usage.by_outcome(task_statuses: %{})
    assert result.by_outcome.other.task_count == 1
    assert result.by_outcome.merged.task_count == 0
  end

  test "since filter excludes older rows" do
    task = KanbanBridge.create_task(%{title: "window", status: "done", assignee: "demo"})

    Usage.append(
      run_id: "run_old",
      task_id: task.id,
      source: "agent",
      provider: "openrouter",
      model_id: "test/m",
      prompt_tokens: 100,
      completion_tokens: 100,
      estimated: true
    )

    # Force old inserted_at
    Svarm.Repo.update_all(
      from(r in Record, where: r.run_id == "run_old"),
      set: [inserted_at: ~U[2020-01-01 00:00:00Z]]
    )

    Usage.append(
      run_id: "run_new",
      task_id: task.id,
      source: "agent",
      provider: "openrouter",
      model_id: "test/m",
      prompt_tokens: 10,
      completion_tokens: 10,
      estimated: true
    )

    since = DateTime.utc_now() |> DateTime.add(-60, :second)
    result = Usage.by_outcome(task_statuses: %{task.id => "done"}, since: since)

    assert result.since == since
    assert result.by_outcome.merged.task_count == 1
    # Only the recent row should contribute tokens roughly 20 total
    assert result.by_outcome.merged.prompt_tokens == 10
    assert result.by_outcome.merged.completion_tokens == 10
  end

  test "merged GitHub PR with review status buckets as merged" do
    task = review_task_with_pr(99)
    Process.put(:github_pr_merged, :merged)

    result = by_outcome_github(task)

    assert result.by_outcome.merged.task_count == 1
    assert result.by_outcome.in_review.task_count == 0
    assert result.by_outcome.merged.estimated == true
    assert result.by_outcome.merged.prompt_tokens == 8
  end

  test "closed unmerged PR with review status stays in_review" do
    task = review_task_with_pr(100)
    Process.put(:github_pr_merged, :closed_unmerged)

    result = by_outcome_github(task)

    assert result.by_outcome.merged.task_count == 0
    assert result.by_outcome.in_review.task_count == 1
  end

  test "GitHub HTTP error does not invent a merge" do
    task = review_task_with_pr(101)
    Process.put(:github_pr_merged, :http_error)

    result = by_outcome_github(task)

    assert result.by_outcome.merged.task_count == 0
    assert result.by_outcome.in_review.task_count == 1
  end

  test "GitHub network error does not invent a merge" do
    task = review_task_with_pr(102)
    Process.put(:github_pr_merged, :network)

    result = by_outcome_github(task)

    assert result.by_outcome.merged.task_count == 0
    assert result.by_outcome.in_review.task_count == 1
  end

  test "local tracker ignores PR fields and stays status-based" do
    task = review_task_with_pr(103)
    Process.put(:github_pr_merged, :flunk)

    result =
      Usage.by_outcome(
        task_statuses: %{task.id => "review"},
        tracker_config: %{kind: :local},
        req: StubReq
      )

    assert result.by_outcome.merged.task_count == 0
    assert result.by_outcome.in_review.task_count == 1
  end

  test "done status does not call GitHub" do
    task = KanbanBridge.create_task(%{title: "done", status: "done", assignee: "demo"})
    append_spend(task.id, "run_done_nopr")
    Process.put(:github_pr_merged, :flunk)

    result =
      Usage.by_outcome(
        task_statuses: %{task.id => "done"},
        tracker_config: @github_config,
        req: StubReq
      )

    assert result.by_outcome.merged.task_count == 1
    assert result.by_outcome.in_review.task_count == 0
  end

  test "review without PR fields does not call GitHub" do
    task = KanbanBridge.create_task(%{title: "review", status: "review", assignee: "demo"})
    append_spend(task.id, "run_review_nopr")
    Process.put(:github_pr_merged, :flunk)

    result =
      Usage.by_outcome(
        task_statuses: %{task.id => "review"},
        tracker_config: @github_config,
        req: StubReq
      )

    assert result.by_outcome.merged.task_count == 0
    assert result.by_outcome.in_review.task_count == 1
  end

  defp review_task_with_pr(number) do
    task = KanbanBridge.create_task(%{title: "review-pr", status: "review", assignee: "demo"})
    append_spend(task.id, "run_pr_#{number}")

    {:ok, _} =
      Coordination.record_pr(task.id, %{
        pr_owner: "acme",
        pr_repo: "app",
        pr_number: number
      })

    task
  end

  defp append_spend(task_id, run_id) do
    Usage.append(
      run_id: run_id,
      task_id: task_id,
      source: "agent",
      provider: "openrouter",
      model_id: "test/m",
      prompt_tokens: 8,
      completion_tokens: 4,
      estimated: true
    )
  end

  defp by_outcome_github(task) do
    Usage.by_outcome(
      task_statuses: %{task.id => "review"},
      tracker_config: @github_config,
      req: StubReq
    )
  end
end
