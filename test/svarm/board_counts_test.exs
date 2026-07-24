defmodule Svarm.BoardCountsTest do
  use ExUnit.Case, async: true

  alias Svarm.Board

  test "counts_by_assignee ignores done and failed" do
    tasks = [
      %{assignee: "pi", status: "todo"},
      %{assignee: "pi", status: "in_progress"},
      %{assignee: "demo", status: "done"},
      %{assignee: nil, status: "review"}
    ]

    assert Board.counts_by_assignee(tasks) == %{"pi" => 2, "default" => 1}
  end

  test "counts_by_status groups tasks" do
    tasks = [
      %{status: "todo"},
      %{status: "todo"},
      %{status: "failed"}
    ]

    assert Board.counts_by_status(tasks) == %{"todo" => 2, "failed" => 1}
  end

  test "wait_reason maps human and agent states" do
    assert Board.wait_reason(%{status: "pending_approval"}) == :approval
    assert Board.wait_reason(%{status: "review"}) == :review
    assert Board.wait_reason(%{status: "in_progress"}) == :running
    assert Board.wait_reason(%{status: "failed"}) == :failed
    assert Board.wait_reason(%{status: "todo"}) == nil
    assert Board.wait_reason_label(:approval) == "Needs approval"
    assert Board.wait_reason_label(:review) == "Needs review"
  end

  test "human_wait_summary counts approval and review only" do
    tasks = [
      %{status: "pending_approval"},
      %{status: "pending_approval"},
      %{status: "review"},
      %{status: "todo"},
      %{status: "in_progress"}
    ]

    assert Board.human_wait_summary(tasks) == %{
             pending_approval: 2,
             review: 1,
             total: 3
           }
  end

  test "pr_url prefers meta then task fields" do
    task = %{pr_url: "https://example.com/pr/1"}
    assert Board.pr_url(task, %{}) == "https://example.com/pr/1"

    assert Board.pr_url(%{}, %{pr_url: "https://example.com/from-meta"}) ==
             "https://example.com/from-meta"

    assert Board.pr_url(%{}, %{}) == nil
  end

  test "reviewer returns present value only" do
    assert Board.reviewer(%{reviewer: "riley"}) == "riley"
    assert Board.reviewer(%{reviewer_login: "riley"}) == "riley"
    assert Board.reviewer(%{}) == nil
  end
end
