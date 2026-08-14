defmodule Svarm.AgentQuestionTest do
  use ExUnit.Case, async: false

  alias Svarm.{AgentQuestion, Coordination, KanbanBridge, Repo}

  setup do
    Repo.delete_all(Coordination)
    :ok
  end

  test "dialog_method?/1 recognizes parked dialogs only" do
    assert AgentQuestion.dialog_method?("confirm")
    assert AgentQuestion.dialog_method?("select")
    assert AgentQuestion.dialog_method?("input")
    assert AgentQuestion.dialog_method?("editor")
    refute AgentQuestion.dialog_method?("notify")
    refute AgentQuestion.dialog_method?("setStatus")
    refute AgentQuestion.dialog_method?(nil)
  end

  test "build_response/3 maps method to RPC body" do
    waiting = %{"request_id" => "q1", "method" => "confirm"}

    assert {:ok, %{"type" => "extension_ui_response", "id" => "q1", "confirmed" => true}} =
             AgentQuestion.build_response(waiting, %{confirmed: true})

    assert {:ok, %{"confirmed" => false}} =
             AgentQuestion.build_response(waiting, %{"confirmed" => "no"})

    assert {:error, :invalid} = AgentQuestion.build_response(waiting, %{})

    select = %{"request_id" => "q2", "method" => "select"}

    assert {:ok, %{"value" => "b"}} =
             AgentQuestion.build_response(select, %{value: "b"})

    assert {:error, :invalid} = AgentQuestion.build_response(select, %{value: "  "})

    input = %{"id" => "q3", "method" => "input"}

    assert {:ok, %{"value" => "hello"}} =
             AgentQuestion.build_response(input, %{value: "hello"})

    editor = %{"request_id" => "q4", "method" => "editor"}

    assert {:ok, %{"value" => "body"}} =
             AgentQuestion.build_response(editor, %{value: "body"})

    assert {:ok, %{"cancelled" => true, "id" => "q1"}} =
             AgentQuestion.build_response(waiting, %{}, cancelled: true)
  end

  test "wait_deadline_ms/2 caps at Svärm timeout and honors pi timeout" do
    now = System.monotonic_time(:millisecond)
    cap = 60_000

    deadline = AgentQuestion.wait_deadline_ms(%{}, cap)
    assert_in_delta deadline - now, cap, 50

    # integer > 1000 is milliseconds
    deadline_ms = AgentQuestion.wait_deadline_ms(%{"timeout" => 2_000}, cap)
    assert_in_delta deadline_ms - now, 2_000, 50

    # integer <= 1000 is seconds
    deadline_s = AgentQuestion.wait_deadline_ms(%{"timeout" => 3}, cap)
    assert_in_delta deadline_s - now, 3_000, 50
  end

  test "answer/2 without a parked question is :not_waiting" do
    assert {:error, :not_waiting} = AgentQuestion.answer("sva_none", %{confirmed: true})
  end

  test "park persists wait; answer without a live runner is :no_runner" do
    task = KanbanBridge.create_task(%{title: "ask", status: "in_progress", assignee: "demo"})

    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} =
          AgentQuestion.park(task.id, %{
            "id" => "q-park",
            "method" => "confirm",
            "message" => "Ship it?"
          })

        send(parent, :parked)
        Process.sleep(5_000)
      end)

    assert_receive :parked, 1_000
    assert KanbanBridge.get_task(task.id).pending_question["prompt"] == "Ship it?"
    assert Coordination.get(task.id).wait_reason == "agent_question"

    Process.exit(pid, :kill)
    wait_until(fn -> Registry.lookup(AgentQuestion.inbox(), task.id) == [] end)

    assert {:error, :no_runner} = AgentQuestion.answer(task.id, %{confirmed: true})
    assert {:ok, :cleared} = AgentQuestion.cancel(task.id)
    assert KanbanBridge.get_task(task.id).pending_question == nil
    assert Coordination.get(task.id).pending_question == nil
  end

  test "answer/2 injects into the registered inbox process" do
    task = KanbanBridge.create_task(%{title: "inject", status: "in_progress", assignee: "demo"})
    parent = self()

    spawn(fn ->
      {:ok, _} =
        AgentQuestion.park(task.id, %{
          "id" => "q-inj",
          "method" => "input",
          "message" => "Name?"
        })

      send(parent, :ready)

      receive do
        {:agent_question_reply, payload} -> send(parent, {:got, payload})
      after
        2_000 -> send(parent, :timeout)
      end
    end)

    assert_receive :ready, 1_000
    assert {:ok, :injected} = AgentQuestion.answer(task.id, %{value: "Ada"})

    assert_receive {:got,
                    %{"type" => "extension_ui_response", "id" => "q-inj", "value" => "Ada"}},
                   1_000
  end

  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      ok? = fun.()
      Process.sleep(20)
      ok?
    end)
    |> Enum.reduce_while(false, fn ok?, _ ->
      cond do
        ok? -> {:halt, :ok}
        System.monotonic_time(:millisecond) >= deadline -> flunk("condition never became true")
        true -> {:cont, false}
      end
    end)
  end
end
