defmodule Svarm.BoardReviewEvidenceTest do
  use ExUnit.Case, async: false

  alias Svarm.{Board, Coordination, KanbanBridge, Usage}

  setup do
    KanbanBridge.delete_all_tasks()
    :ok
  end

  test "review_evidence empty local review card" do
    task =
      KanbanBridge.create_task(%{
        title: "Empty evidence",
        status: "review",
        assignee: "demo",
        attempts: 0
      })

    card = Board.list_tasks() |> Enum.find(&(&1.id == task.id))
    evidence = Board.review_evidence(card, %{}, nil)

    assert evidence.pr_url == nil
    assert evidence.attempts == 0
    assert evidence.agent == "demo"
    assert evidence.model == nil
    assert evidence.cost == nil
    assert evidence.age.label == "since created"
    assert is_integer(evidence.age.seconds)
    assert Board.review_glance(card) == :no_pr
  end

  test "review_evidence populated from coordination PR, meta, cost, usage" do
    task =
      KanbanBridge.create_task(%{
        title: "Full evidence",
        status: "review",
        assignee: "demo",
        attempts: 2
      })

    assert {:ok, _} =
             Coordination.record_pr(task.id, "https://github.com/example/repo/pull/42", [])

    Usage.append(
      run_id: "run_evidence_1",
      task_id: task.id,
      source: "agent",
      provider: "openrouter",
      model_id: "test/model",
      prompt_tokens: 10,
      completion_tokens: 5,
      estimated: true
    )

    card = Board.list_tasks() |> Enum.find(&(&1.id == task.id))
    cost = Usage.task_cost_summary(task.id)

    meta = %{
      display_name: "Demo Agent",
      model: "meta/model",
      attempt: 3
    }

    evidence = Board.review_evidence(card, meta, cost)

    assert evidence.pr_url == "https://github.com/example/repo/pull/42"
    # task.attempts wins over meta attempt when present on the card
    assert evidence.attempts == 2
    assert evidence.agent == "Demo Agent"
    assert evidence.model == "meta/model"
    assert evidence.cost.record_count >= 1
    assert evidence.cost.estimated == true
    assert evidence.age.label == "since last usage"
    assert Board.review_glance(card) == :has_pr
  end

  test "review_evidence falls back to ledger model when meta has none" do
    task =
      KanbanBridge.create_task(%{
        title: "Ledger model",
        status: "review",
        assignee: "demo"
      })

    Usage.append(
      run_id: "run_evidence_2",
      task_id: task.id,
      source: "agent",
      provider: "openrouter",
      model_id: "ledger/model",
      prompt_tokens: 1,
      completion_tokens: 1,
      estimated: true
    )

    card = Board.list_tasks() |> Enum.find(&(&1.id == task.id))
    evidence = Board.review_evidence(card, %{}, Usage.task_cost_summary(task.id))

    assert evidence.model == "ledger/model"
  end
end
