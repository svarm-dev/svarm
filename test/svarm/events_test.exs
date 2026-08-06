defmodule Svarm.EventsTest do
  use ExUnit.Case, async: false

  alias Svarm.{Events, RunLog}

  test "broadcast delivers to subscriber" do
    Events.subscribe()

    assert :ok =
             Phoenix.PubSub.broadcast(Svarm.PubSub, Events.topic(), {:ping, :test})

    assert_receive {:ping, :test}, 500
  end

  test "broadcast_agent_line persists once and delivers redacted line" do
    Events.subscribe()
    task_id = "evt_runlog_#{System.unique_integer([:positive])}"

    Events.broadcast_agent_line(task_id, "hello from agent\n")

    assert_receive {:agent_line, ^task_id, "hello from agent\n"}, 500
    assert RunLog.get(task_id) == "hello from agent\n"

    # Second broadcast appends; content is not duplicated beyond the two writes
    Events.broadcast_agent_line(task_id, "second line\n")
    assert_receive {:agent_line, ^task_id, "second line\n"}, 500
    assert RunLog.get(task_id) == "hello from agent\nsecond line\n"
  end

  test "persist_agent_line writes RunLog without PubSub" do
    Events.subscribe()
    task_id = "evt_persist_#{System.unique_integer([:positive])}"

    assert Events.persist_agent_line(task_id, "marker\n") == "marker\n"
    assert RunLog.get(task_id) == "marker\n"
    refute_receive {:agent_line, ^task_id, _}, 100
  end

  test "broadcast_run_started persists started banner once" do
    Events.subscribe()
    task_id = "evt_start_#{System.unique_integer([:positive])}"

    meta = %{display_name: "Demo", role: "Code", attempt: 1}
    Events.broadcast_run_started(task_id, meta)

    assert_receive {:run_started, ^task_id, ^meta}, 500
    log = RunLog.get(task_id)
    assert log =~ "Demo (Code) started · attempt 1"
    # Single banner — not duplicated by a second writer
    assert match?([_], Regex.scan(~r/started · attempt/, log))
  end

  test "broadcast_run_finished persists finished banner once" do
    Events.subscribe()
    task_id = "evt_fin_#{System.unique_integer([:positive])}"

    Events.broadcast_run_finished(task_id, 0)
    assert_receive {:run_finished, ^task_id, 0}, 500

    log = RunLog.get(task_id)
    assert log =~ "run finished (exit 0)"
    assert match?([_], Regex.scan(~r/run finished/, log))
  end

  test "broadcast_task_updated persists status marker once" do
    task_id = "evt_status_#{System.unique_integer([:positive])}"
    task = %{id: task_id, status: "in_progress", title: "T"}

    Events.broadcast_task_updated(task)
    assert RunLog.get(task_id) == "[board] status → in_progress\n"

    # Second call appends a second status line (one write per broadcast, not N×clients)
    Events.broadcast_task_updated(%{task | status: "review"})

    assert RunLog.get(task_id) ==
             "[board] status → in_progress\n[board] status → review\n"
  end
end
