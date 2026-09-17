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
    assert evidence.ci.state == :na
    assert evidence.checklist == []
    assert Board.review_glance(card) == :no_pr
  end

  test "review_evidence CI states from coordination" do
    task =
      KanbanBridge.create_task(%{
        title: "CI evidence",
        status: "review",
        assignee: "demo"
      })

    assert {:ok, _} =
             Coordination.record_pr(task.id, "https://github.com/example/repo/pull/7", [])

    assert {:ok, _} =
             Coordination.upsert(task.id, %{
               ci_last_conclusion: "passed",
               ci_context_summary: "CI passed (2 checks)",
               ci_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    card = Board.list_tasks() |> Enum.find(&(&1.id == task.id))
    evidence = Board.review_evidence(card)

    assert evidence.ci.state == :pass
    assert evidence.ci.summary =~ "CI passed"
    assert %DateTime{} = evidence.ci.checked_at

    assert {:ok, _} = Coordination.upsert(task.id, %{ci_last_conclusion: "failed"})
    card = Board.list_tasks() |> Enum.find(&(&1.id == task.id))
    assert Board.review_evidence(card).ci.state == :fail

    assert {:ok, _} = Coordination.upsert(task.id, %{ci_last_conclusion: "in_progress"})
    card = Board.list_tasks() |> Enum.find(&(&1.id == task.id))
    assert Board.review_evidence(card).ci.state == :pending

    assert {:ok, _} = Coordination.upsert(task.id, %{ci_last_conclusion: "unknown"})
    card = Board.list_tasks() |> Enum.find(&(&1.id == task.id))
    assert Board.review_evidence(card).ci.state == :unknown
    # Column chip path — must not need Usage.for_task/1
    assert Board.review_ci(card).state == :unknown
  end

  test "review_ci reads attached fields without a usage row" do
    task =
      KanbanBridge.create_task(%{
        title: "Chip only",
        status: "review",
        assignee: "demo"
      })

    assert {:ok, _} =
             Coordination.upsert(task.id, %{
               ci_last_conclusion: "failed",
               ci_context_summary: "CI failed (1 checks)",
               ci_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
             })

    card = Board.list_tasks() |> Enum.find(&(&1.id == task.id))
    ci = Board.review_ci(card)

    assert ci.state == :fail
    assert ci.summary =~ "CI failed"
    assert %DateTime{} = ci.checked_at
    assert Usage.for_task(task.id) == []
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

  test "checklist_states maps known ids from evidence and custom to unknown" do
    items = [
      %{id: "pr", label: "Pull request"},
      %{id: "ci", label: "CI"},
      %{id: "cost", label: "Cost receipt"},
      %{id: "docs", label: "Docs updated"}
    ]

    empty = Board.checklist_states(items, %{pr_url: nil, ci: %{state: :na}, cost: nil})

    assert Enum.map(empty, & &1.state) == [:na, :na, :na, :unknown]

    filled =
      Board.checklist_states(items, %{
        pr_url: "https://github.com/example/repo/pull/1",
        ci: %{state: :fail},
        cost: %{record_count: 1, total_cost_usd: 0.1, estimated: true}
      })

    assert Enum.map(filled, & &1.state) == [:pass, :fail, :pass, :unknown]
  end

  test "review_evidence checklist follows WORKFLOW store" do
    task =
      KanbanBridge.create_task(%{
        title: "Checklist evidence",
        status: "review",
        assignee: "demo"
      })

    card = Board.list_tasks() |> Enum.find(&(&1.id == task.id))
    assert Board.review_evidence(card).checklist == []

    wf = %Svarm.Workflow{
      config: %{"review" => %{"checklist" => ["pr", "ci", %{"id" => "docs", "label" => "Docs"}]}},
      prompt_template: "Do {{issue.id}}",
      path: "test.md"
    }

    previous = :sys.get_state(Svarm.Workflow.Store)
    :sys.replace_state(Svarm.Workflow.Store, fn s -> %{s | workflow: wf} end)

    try do
      evidence = Board.review_evidence(card)
      assert Enum.map(evidence.checklist, & &1.id) == ["pr", "ci", "docs"]
      assert Enum.map(evidence.checklist, & &1.state) == [:na, :na, :unknown]
    after
      :sys.replace_state(Svarm.Workflow.Store, fn _ -> previous end)
    end
  end
end
