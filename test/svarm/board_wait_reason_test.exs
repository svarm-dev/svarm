defmodule Svarm.BoardWaitReasonTest do
  use ExUnit.Case, async: false

  alias Svarm.{Board, Coordination, Repo}

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
