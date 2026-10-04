defmodule Svarm.OrchestratorSendBackTest do
  use ExUnit.Case, async: false

  alias Svarm.{Coordination, KanbanBridge, Orchestrator, Repo}
  alias Svarm.Workflow.Env

  defmodule PatchFailTracker do
    def get_issue(_config, id) do
      case Svarm.KanbanBridge.get_task(id) do
        nil -> {:error, :not_found}
        task -> {:ok, task}
      end
    end

    def update_status(_config, _id, _status) do
      {:error, %{type: :forbidden, message: "nope"}}
    end
  end

  setup do
    KanbanBridge.delete_all_tasks()
    Repo.delete_all(Coordination)

    original = :sys.get_state(Orchestrator)

    :sys.replace_state(Orchestrator, fn state ->
      %{
        state
        | tracker: Svarm.Tracker.Local,
          tracker_config: %{kind: :local, active_states: ["todo", "in_progress"]},
          completed: MapSet.new(),
          approved_once: MapSet.new(),
          ci_resume_caps: %{enabled: false, max_attempts: 3, skip_draft: true},
          review_resume_caps: %{enabled: false}
      }
    end)

    on_exit(fn ->
      if Process.whereis(Orchestrator) do
        :sys.replace_state(Orchestrator, fn _ -> original end)
      end
    end)

    :ok
  end

  defp put_review_changes_requested(opts \\ []) do
    task =
      KanbanBridge.create_task(%{
        title: "review card",
        status: "review",
        assignee: "cody"
      })

    attrs =
      %{
        review_decision: "changes_requested",
        review_context_summary: "## Review feedback (changes requested)\n\nPlease fix the test",
        review_last_head_sha: "sha_a"
      }
      |> Map.merge(Keyword.get(opts, :coord, %{}))

    {:ok, _} = Coordination.upsert(task.id, attrs)
    task
  end

  test "send_back moves a changes-requested review ticket to todo and counts one resume" do
    task = put_review_changes_requested(coord: %{ci_resume_count: 1})

    :sys.replace_state(Orchestrator, fn state ->
      %{
        state
        | completed: MapSet.put(state.completed, task.id),
          approved_once: MapSet.put(state.approved_once, task.id)
      }
    end)

    assert Orchestrator.send_back(task.id) == :ok

    task = Svarm.KanbanBridge.get_task(task.id)
    assert task.status == "todo"

    coord = Coordination.get(task.id)
    assert coord.ci_resume_count == 2
    assert coord.review_decision == "changes_requested"
    assert coord.review_context_summary =~ "changes requested"

    state = :sys.get_state(Orchestrator)
    refute MapSet.member?(state.completed, task.id)
    # Gated assignees re-enter pending_approval on the next poll.
    refute MapSet.member?(state.approved_once, task.id)
  end

  test "send_back removes approved_once so gated assignees re-enter pending_approval" do
    task = put_review_changes_requested()

    :sys.replace_state(Orchestrator, fn state ->
      %{state | approved_once: MapSet.put(state.approved_once, task.id)}
    end)

    assert Orchestrator.send_back(task.id) == :ok
    refute MapSet.member?(:sys.get_state(Orchestrator).approved_once, task.id)
  end

  test "send_back rejects when the shared circuit is already open" do
    task = put_review_changes_requested(coord: %{ci_circuit_open: true, ci_resume_count: 3})

    assert Orchestrator.send_back(task.id) == {:error, :circuit_open}

    assert Svarm.KanbanBridge.get_task(task.id).status == "review"
    coord = Coordination.get(task.id)
    assert coord.ci_resume_count == 3
  end

  test "send_back rejects when the shared count is already at the cap (circuit not yet flagged)" do
    task = put_review_changes_requested(coord: %{ci_resume_count: 3})

    assert Orchestrator.send_back(task.id) == {:error, :circuit_open}
    assert Svarm.KanbanBridge.get_task(task.id).status == "review"
    assert Coordination.get(task.id).ci_resume_count == 3
  end

  test "send_back rejects a review card without recorded changes-requested summary" do
    task = put_review_changes_requested(coord: %{review_context_summary: nil})

    assert Orchestrator.send_back(task.id) == {:error, :no_review_context}
    assert Svarm.KanbanBridge.get_task(task.id).status == "review"
    assert Coordination.get(task.id).ci_resume_count == 0
  end

  test "send_back rejects tasks not in review" do
    task =
      KanbanBridge.create_task(%{title: "todo card", status: "todo", assignee: "cody"})

    {:ok, _} =
      Coordination.upsert(task.id, %{
        review_decision: "changes_requested",
        review_context_summary: "fix it"
      })

    assert Orchestrator.send_back(task.id) == {:error, :not_in_review}
    assert Svarm.KanbanBridge.get_task(task.id).status == "todo"
  end

  test "send_back PATCH failure does not count a resume" do
    task = put_review_changes_requested()

    :sys.replace_state(Orchestrator, fn state ->
      %{state | tracker: PatchFailTracker}
    end)

    assert {:error, %{type: :forbidden}} = Orchestrator.send_back(task.id)

    coord = Coordination.get(task.id)
    assert coord.ci_resume_count == 0
    assert Svarm.KanbanBridge.get_task(task.id).status == "review"
  end

  test "send_back flash copy covers the failure reasons" do
    assert Svarm.Board.send_back_flash_error(:not_in_review) == "Task is not awaiting review"
    assert Svarm.Board.send_back_flash_error(:circuit_open) =~ "exhausted"
    assert Svarm.Board.send_back_flash_error(:no_review_context) =~ "review summary"
    assert Svarm.Board.send_back_flash_error(%{oops: true}) =~ "Could not send back"
  end

  # The board-level default must stay opt-in: this feature must not flip it.
  test "review_resume default stays off (WORKFLOW and env path)" do
    System.delete_env("SVARM_REVIEW_RESUME_ENABLED")

    on_exit(fn -> System.delete_env("SVARM_REVIEW_RESUME_ENABLED") end)

    assert Env.env_bool("SVARM_REVIEW_RESUME_ENABLED", false) == false
    assert Svarm.ReviewResume.load_caps(nil).enabled == false
  end
end
