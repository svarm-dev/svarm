defmodule Svarm.Usage.OutcomesTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Svarm.{KanbanBridge, Usage}
  alias Svarm.Repo
  alias Svarm.Usage.Record

  setup do
    KanbanBridge.delete_all_tasks()
    Repo.delete_all(Record)
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
end
