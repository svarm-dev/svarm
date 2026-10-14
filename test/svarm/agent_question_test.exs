defmodule Svarm.AgentQuestionTest do
  use ExUnit.Case, async: false

  alias Svarm.{AgentQuestion, Coordination, Events, KanbanBridge, Repo, RunLog}

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

  test "flash_error/1 covers answer and cancel reasons" do
    assert AgentQuestion.flash_error(:not_waiting) =~ "waiting"
    assert AgentQuestion.flash_error(:no_runner) =~ "no longer waiting"
    assert AgentQuestion.flash_error(:invalid) =~ "does not match"
    assert AgentQuestion.flash_error(:not_found) =~ "not found"
    assert AgentQuestion.flash_error(:other) =~ "other"
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

  test "park persists wait; answer without a live runner is queued until cancel" do
    task = KanbanBridge.create_task(%{title: "ask", status: "in_progress", assignee: "demo"})
    pid = park_in_spawn(task.id, confirm_event("q-park"))

    assert KanbanBridge.get_task(task.id).pending_question["prompt"] == "Ship it?"
    assert Coordination.get(task.id).wait_reason == "agent_question"

    kill_runner(pid, task.id)

    assert {:ok, :queued} = AgentQuestion.answer(task.id, %{confirmed: true})
    assert KanbanBridge.get_task(task.id).pending_question["prompt"] == "Ship it?"
    assert {:ok, :cleared} = AgentQuestion.cancel(task.id)
    assert KanbanBridge.get_task(task.id).pending_question == nil
    assert Coordination.get(task.id).pending_question == nil
    assert [] = repark_replies(task.id, confirm_event("q-park"))
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
    assert KanbanBridge.get_task(task.id).pending_question == nil
    assert Coordination.get(task.id).pending_question == nil
    assert {:error, :not_waiting} = AgentQuestion.answer(task.id, %{value: "Bob"})

    assert_receive {:got,
                    %{"type" => "extension_ui_response", "id" => "q-inj", "value" => "Ada"}},
                   1_000
  end

  test "answer/2 with a stale request_id does not inject a later dialog" do
    task = KanbanBridge.create_task(%{title: "stale", status: "in_progress", assignee: "demo"})
    parent = self()

    spawn(fn ->
      {:ok, _} =
        AgentQuestion.park(task.id, %{
          "id" => "q-new",
          "method" => "input",
          "message" => "Later?"
        })

      send(parent, :ready)

      receive do
        {:agent_question_reply, payload} -> send(parent, {:got, payload})
      after
        2_000 -> send(parent, :timeout)
      end
    end)

    assert_receive :ready, 1_000

    assert {:error, :invalid} =
             AgentQuestion.answer(task.id, %{value: "nope", request_id: "q-old"})

    assert KanbanBridge.get_task(task.id).pending_question["request_id"] == "q-new"
    refute_received {:got, _}
  end

  test "park/3 without a request id is :invalid and does not persist" do
    task = KanbanBridge.create_task(%{title: "no id", status: "in_progress", assignee: "demo"})

    assert {:error, :invalid} =
             AgentQuestion.park(task.id, %{"method" => "confirm", "message" => "Ship it?"})

    assert KanbanBridge.get_task(task.id).pending_question == nil
    assert Coordination.get(task.id) == nil or Coordination.get(task.id).pending_question == nil
  end

  test "cancel/1 returns :invalid instead of raising when request_id is missing" do
    task =
      KanbanBridge.create_task(%{title: "no id cancel", status: "in_progress", assignee: "demo"})

    assert {:ok, _} = KanbanBridge.put_pending_question(task.id, %{prompt: "Ship it?"})

    parent = self()

    spawn(fn ->
      {:ok, _} = Registry.register(AgentQuestion.inbox(), task.id, :waiting)
      send(parent, :ready)
      Process.sleep(5_000)
    end)

    assert_receive :ready, 1_000
    assert {:error, :invalid} = AgentQuestion.cancel(task.id)
  end

  test "queued answer is delivered once when the same request parks" do
    task = KanbanBridge.create_task(%{title: "race", status: "in_progress", assignee: "demo"})
    pid = park_in_spawn(task.id, input_event("q-race"))
    kill_runner(pid, task.id)

    assert {:ok, :queued} = AgentQuestion.answer(task.id, %{value: "Ada"})

    assert [%{"type" => "extension_ui_response", "id" => "q-race", "value" => "Ada"}] =
             repark_replies(task.id, input_event("q-race"))
  end

  test "a second answer while queued is rejected and is not sent" do
    task = KanbanBridge.create_task(%{title: "twice", status: "in_progress", assignee: "demo"})
    pid = park_in_spawn(task.id, input_event("q-twice"))
    kill_runner(pid, task.id)

    assert {:ok, :queued} = AgentQuestion.answer(task.id, %{value: "Ada"})
    assert {:error, :already_answered} = AgentQuestion.answer(task.id, %{value: "Bob"})

    assert [%{"id" => "q-twice", "value" => "Ada"}] =
             repark_replies(task.id, input_event("q-twice"))
  end

  test "after inject, a second click is :not_waiting" do
    task =
      KanbanBridge.create_task(%{title: "second click", status: "in_progress", assignee: "demo"})

    park_in_spawn(task.id, input_event("q-second"))
    assert {:ok, :injected} = AgentQuestion.answer(task.id, %{value: "Ada"})
    assert {:error, :not_waiting} = AgentQuestion.answer(task.id, %{value: "Bob"})
  end

  test "a past deadline does not queue and is not delivered by a later park" do
    task = KanbanBridge.create_task(%{title: "past", status: "in_progress", assignee: "demo"})
    past = System.system_time(:millisecond) - 1_000

    assert {:ok, _} =
             KanbanBridge.put_pending_question(task.id, %{
               prompt: "Ship it?",
               method: "confirm",
               request_id: "q-past",
               deadline_at: past
             })

    assert {:error, :no_runner} =
             AgentQuestion.answer(task.id, %{confirmed: true, request_id: "q-past"})

    assert [] = repark_replies(task.id, confirm_event("q-past"))
  end

  test "a queued answer past its deadline is not delivered" do
    task =
      KanbanBridge.create_task(%{title: "expire", status: "in_progress", assignee: "demo"})

    deadline_at = System.system_time(:millisecond) + 400

    assert {:ok, _} =
             KanbanBridge.put_pending_question(task.id, %{
               prompt: "Ship it?",
               method: "confirm",
               request_id: "q-exp",
               deadline_at: deadline_at
             })

    Events.subscribe()
    flush_task_updated()

    assert {:ok, :queued} = AgentQuestion.answer(task.id, %{confirmed: true, request_id: "q-exp"})

    assert_receive {:task_updated, %{id: id, reason: :agent_question_answer_expired} = payload},
                   2_000

    assert id == task.id
    refute Map.has_key?(payload, :status)
    assert KanbanBridge.get_task(task.id).pending_question["prompt"] == "Ship it?"

    assert {:error, :no_runner} =
             AgentQuestion.answer(task.id, %{confirmed: true, request_id: "q-exp"})

    assert [] = repark_replies(task.id, confirm_event("q-exp"))
  end

  test "cancel drops a queued answer so a later park receives nothing" do
    task =
      KanbanBridge.create_task(%{title: "cancel queue", status: "in_progress", assignee: "demo"})

    pid = park_in_spawn(task.id, confirm_event("q-cancel"))
    kill_runner(pid, task.id)

    assert {:ok, :queued} = AgentQuestion.answer(task.id, %{confirmed: true})
    assert {:ok, :cleared} = AgentQuestion.cancel(task.id)
    assert KanbanBridge.get_task(task.id).pending_question == nil
    assert [] = repark_replies(task.id, confirm_event("q-cancel"))
  end

  test "a queued answer is not sent when a different request id parks" do
    task =
      KanbanBridge.create_task(%{title: "other id", status: "in_progress", assignee: "demo"})

    pid = park_in_spawn(task.id, confirm_event("q-a"))
    kill_runner(pid, task.id)
    assert {:ok, :queued} = AgentQuestion.answer(task.id, %{confirmed: true, request_id: "q-a"})

    assert [] = repark_replies(task.id, confirm_event("q-b"))
    assert [] = repark_replies(task.id, confirm_event("q-a"))
  end

  test "deadline_at survives park on the task row and coordination" do
    task =
      KanbanBridge.create_task(%{title: "deadline", status: "in_progress", assignee: "demo"})

    before = System.monotonic_time(:millisecond)
    assert {:ok, deadline_ms} = AgentQuestion.park(task.id, confirm_event("q-dead"))
    after_mono = System.monotonic_time(:millisecond)

    assert deadline_ms >= before + AgentQuestion.timeout_ms() - 50
    assert deadline_ms <= after_mono + AgentQuestion.timeout_ms() + 50

    row = KanbanBridge.get_task(task.id).pending_question
    coord = Coordination.get(task.id).pending_question
    assert is_integer(row["deadline_at"])
    assert row["deadline_at"] == coord["deadline_at"]

    assert_in_delta row["deadline_at"] - System.system_time(:millisecond),
                    AgentQuestion.timeout_ms(),
                    1_000

    refute Map.has_key?(row, "timeout")

    assert {:ok, _} =
             KanbanBridge.put_pending_question(task.id, %{
               prompt: "Ship it?",
               request_id: "q-str",
               deadline_at: "100"
             })

    refute Map.has_key?(KanbanBridge.get_task(task.id).pending_question, "deadline_at")
  end

  test "clear/1 drops a queued answer so a later park receives nothing" do
    task =
      KanbanBridge.create_task(%{title: "clear queue", status: "in_progress", assignee: "demo"})

    pid = park_in_spawn(task.id, confirm_event("q-clear-q"))
    kill_runner(pid, task.id)
    assert {:ok, :queued} = AgentQuestion.answer(task.id, %{confirmed: true})

    assert :ok = AgentQuestion.clear(task.id)
    assert KanbanBridge.get_task(task.id).pending_question == nil
    assert [] = repark_replies(task.id, confirm_event("q-clear-q"))
  end

  test "clear/1 does not PubSub in_progress or log a status line after review" do
    Events.subscribe()

    task =
      KanbanBridge.create_task(%{
        title: "clear after review",
        status: "in_progress",
        assignee: "demo"
      })

    {:ok, _} =
      AgentQuestion.park(task.id, %{
        "id" => "q-clr",
        "method" => "confirm",
        "message" => "Ship it?"
      })

    KanbanBridge.update_status(task.id, "review")
    flush_task_updated()

    AgentQuestion.clear(task.id)

    updates = collect_task_updated(task.id, 200)
    refute Enum.any?(updates, &(&1[:status] == "in_progress"))
    assert Enum.any?(updates, fn u -> u[:wait_reason] == nil and u[:pending_question] == nil end)

    assert KanbanBridge.get_task(task.id).status == "review"
    assert KanbanBridge.get_task(task.id).pending_question == nil
    refute RunLog.get(task.id) =~ ~r/status → in_progress\n$/
  end

  test "clear/1 on coord-only wait broadcasts wait fields without status" do
    Events.subscribe()
    id = "sva_coord_clear_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Coordination.upsert(id, %{
        wait_reason: "agent_question",
        pending_question: %{"prompt" => "Hi?", "request_id" => "q-gh"}
      })

    flush_task_updated()
    AgentQuestion.clear(id)

    assert_receive {:task_updated, payload}, 500
    assert payload.id == id
    assert payload.wait_reason == nil
    assert payload.pending_question == nil
    refute Map.has_key?(payload, :status)
    assert Coordination.get(id).wait_reason == nil
    refute RunLog.get(id) =~ "status →"
  end

  defp confirm_event(id) do
    %{"id" => id, "method" => "confirm", "message" => "Ship it?"}
  end

  defp input_event(id) do
    %{"id" => id, "method" => "input", "message" => "Name?"}
  end

  defp park_in_spawn(task_id, event) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = AgentQuestion.park(task_id, event)
        send(parent, {:parked, self()})
        Process.sleep(30_000)
      end)

    assert_receive {:parked, ^pid}, 1_000
    pid
  end

  defp kill_runner(pid, task_id) do
    Process.exit(pid, :kill)
    wait_until(fn -> Registry.lookup(AgentQuestion.inbox(), task_id) == [] end)
  end

  defp repark_replies(task_id, event, wait_ms \\ 300) do
    parent = self()

    spawn(fn ->
      {:ok, _} = AgentQuestion.park(task_id, event)
      send(parent, :reparked)

      collect = fn collect, acc ->
        receive do
          {:agent_question_reply, payload} -> collect.(collect, [payload | acc])
        after
          wait_ms -> send(parent, {:replies, Enum.reverse(acc)})
        end
      end

      collect.(collect, [])
    end)

    assert_receive :reparked, 1_000
    assert_receive {:replies, replies}, wait_ms + 1_000
    replies
  end

  defp flush_task_updated do
    receive do
      {:task_updated, _} -> flush_task_updated()
    after
      50 -> :ok
    end
  end

  defp collect_task_updated(task_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_task_updated(task_id, deadline, [])
  end

  defp collect_task_updated(task_id, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:task_updated, %{id: ^task_id} = payload} ->
          collect_task_updated(task_id, deadline, [payload | acc])

        {:task_updated, _} ->
          collect_task_updated(task_id, deadline, acc)
      after
        max(remaining, 1) -> Enum.reverse(acc)
      end
    end
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
