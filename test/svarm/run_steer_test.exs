defmodule Svarm.RunSteerTest do
  use ExUnit.Case, async: false

  alias Svarm.{KanbanBridge, RunSteer}

  test "flash_error/1 covers inject reasons" do
    assert RunSteer.flash_error(:empty) =~ "empty"
    assert RunSteer.flash_error(:not_running) =~ "No live Pi RPC"
    assert RunSteer.flash_error(:unsupported) =~ "Pi RPC"
    assert RunSteer.flash_error(:question_pending) =~ "question"
    assert RunSteer.flash_error(:other) =~ "other"
  end

  test "inject/2 rejects blank text" do
    assert {:error, :empty} = RunSteer.inject("sva_none", "  ")
    assert {:error, :empty} = RunSteer.inject("sva_none", "")
  end

  test "inject/2 without a live session is :not_running" do
    assert {:error, :not_running} = RunSteer.inject("sva_none", "try tests")
  end

  test "inject/2 sends {:steer, text} to the registered worker" do
    id = "sva_steer_ok"
    assert :ok = RunSteer.register(id)
    assert {:ok, :injected} = RunSteer.inject(id, "  try the other approach  ")
    assert_receive {:steer, "try the other approach"}
    RunSteer.unregister()
  end

  test "inject/2 refuses while a question is parked" do
    task =
      KanbanBridge.create_task(%{
        title: "steer blocked",
        status: "in_progress",
        assignee: "demo"
      })

    assert {:ok, _} =
             KanbanBridge.put_pending_question(task.id, %{
               prompt: "Ship it?",
               method: "confirm",
               request_id: "q-steer"
             })

    assert :ok = RunSteer.register(task.id)
    assert {:error, :question_pending} = RunSteer.inject(task.id, "try tests")
    refute_received {:steer, _}
    RunSteer.unregister()
  end
end
