defmodule Svarm.BoardWaitReasonTest do
  use ExUnit.Case, async: false

  alias Svarm.{Board, Coordination, KanbanBridge, Repo}

  setup do
    Repo.delete_all(Coordination)
    :ok
  end

  test "wait_reason review is :review without circuit" do
    assert Board.wait_reason(%{status: "review", id: "t1"}) == :review
    assert Board.wait_reason_label(:review) == "Needs review"
  end

  test "wait_reason review becomes :ci_circuit when coordination circuit open" do
    {:ok, _} = Coordination.upsert("t_circuit", %{ci_circuit_open: true})
    assert Board.wait_reason(%{status: "review", id: "t_circuit"}) == :ci_circuit
    assert Board.wait_reason_label(:ci_circuit) == "CI retries exhausted"
  end

  test "wait_reason review becomes :changes_requested when decision recorded" do
    {:ok, _} = Coordination.upsert("t_changes", %{review_decision: "changes_requested"})
    assert Board.wait_reason(%{status: "review", id: "t_changes"}) == :changes_requested
    assert Board.wait_reason_label(:changes_requested) == "Changes requested"
  end

  test "wait_reason uses preloaded review_decision without extra query" do
    assert Board.wait_reason(%{status: "review", id: "x", review_decision: "changes_requested"}) ==
             :changes_requested

    assert Board.wait_reason(%{status: "review", id: "x", review_decision: "none"}) == :review
    assert Board.wait_reason(%{status: "review", id: "x", review_decision: nil}) == :review
  end

  test "ci_circuit wins over changes_requested" do
    assert Board.wait_reason(%{
             status: "review",
             id: "x",
             ci_circuit_open: true,
             review_decision: "changes_requested"
           }) == :ci_circuit
  end

  test "wait_reason in_progress becomes :agent_question when a question is pending" do
    assert Board.wait_reason(%{status: "in_progress"}) == :running

    assert Board.wait_reason(%{
             status: "in_progress",
             wait_reason: "agent_question",
             pending_question: %{"prompt" => "Which file?"}
           }) == :agent_question

    assert Board.wait_reason_label(:agent_question) == "Waiting for answer"

    assert Board.pending_question(%{pending_question: %{"prompt" => "Which file?"}}) ==
             %{"prompt" => "Which file?"}
  end

  test "wait_reason pending_approval becomes :budget_overage when held" do
    assert Board.wait_reason(%{status: "pending_approval"}) == :approval

    assert Board.wait_reason(%{
             status: "pending_approval",
             wait_reason: "budget_overage"
           }) == :budget_overage

    assert Board.wait_reason_label(:budget_overage) == "Over budget"
  end

  test "attach_coordination overlays wait fields from coordination" do
    task =
      KanbanBridge.create_task(%{title: "github-shaped", status: "in_progress", assignee: "demo"})

    {:ok, _} =
      Coordination.upsert(task.id, %{
        wait_reason: "agent_question",
        pending_question: %{"prompt" => "from coord", "request_id" => "c1"}
      })

    found = Board.get_task(task.id)
    assert found.pending_question["prompt"] == "from coord"
    assert Board.wait_reason(found) == :agent_question
  end

  test "pr_url prefers coordination row" do
    {:ok, _} =
      Coordination.record_pr("t_pr", "https://github.com/o/r/pull/42")

    assert Board.pr_url(%{id: "t_pr"}, %{}) == "https://github.com/o/r/pull/42"
  end

  test "pr_url uses preloaded field first" do
    assert Board.pr_url(%{id: "p", pr_url: "https://github.com/o/r/pull/1"}, %{}) ==
             "https://github.com/o/r/pull/1"
  end
end
