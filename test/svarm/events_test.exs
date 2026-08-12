defmodule Svarm.EventsTest do
  use ExUnit.Case, async: false

  alias Svarm.{Events, RunLog, StreamEvent}

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

  test "broadcast_stream_event persists text projection and restores via RunLog" do
    Events.subscribe()
    task_id = "evt_typed_#{System.unique_integer([:positive])}"

    start = StreamEvent.new(:tool_start, %{name: "bash", args: %{"command" => "ls"}})
    assert :ok = Events.broadcast_stream_event(task_id, start)

    assert_receive {:stream_event, ^task_id, %{kind: :tool_start, payload: payload}}, 500
    assert payload[:name] == "bash"
    assert_receive {:agent_line, ^task_id, "\n$ bash ls\n"}, 500
    assert RunLog.get(task_id) == "\n$ bash ls\n"

    fail =
      StreamEvent.new(:tool_end, %{name: "bash", status: :error, result: "mix: command not found"})

    assert :ok = Events.broadcast_stream_event(task_id, fail)
    assert_receive {:stream_event, ^task_id, %{kind: :tool_end, payload: %{status: :error}}}, 500
    assert_receive {:agent_line, ^task_id, line}, 500
    assert line =~ "[tool bash failed]"
    assert RunLog.get(task_id) =~ "$ bash ls"
    assert RunLog.get(task_id) =~ "[tool bash failed]"
    assert RunLog.get(task_id) =~ "mix: command not found"
  end

  test "successful tool_end broadcasts typed event without a text line" do
    Events.subscribe()
    task_id = "evt_tool_ok_#{System.unique_integer([:positive])}"

    assert :ok =
             Events.broadcast_stream_event(
               task_id,
               StreamEvent.new(:tool_end, %{name: "bash", status: :ok})
             )

    assert_receive {:stream_event, ^task_id, %{kind: :tool_end, payload: %{status: :ok}}}, 500
    refute_receive {:agent_line, ^task_id, _}, 100
    assert RunLog.get(task_id) == ""
  end

  test "broadcast_stream_event redacts secrets in typed payload and text" do
    Events.subscribe()
    task_id = "evt_secret_#{System.unique_integer([:positive])}"
    secret = "sk-ant-abcdefghijklmnopqrstuvwxyz"

    assert :ok =
             Events.broadcast_stream_event(
               task_id,
               StreamEvent.new(:text, %{text: "token=#{secret}\n"})
             )

    assert_receive {:stream_event, ^task_id, %{kind: :text, payload: %{text: redacted}}}, 500
    refute redacted =~ secret
    assert_receive {:agent_line, ^task_id, line}, 500
    refute line =~ secret
    refute RunLog.get(task_id) =~ secret
  end

  test "broadcast_stream_event redacts secrets inside MCP content lists" do
    Events.subscribe()
    task_id = "evt_list_secret_#{System.unique_integer([:positive])}"
    secret = "sk-ant-abcdefghijklmnopqrstuvwxyz"

    result = %{"content" => [%{"type" => "text", "text" => "token=#{secret}"}]}

    assert :ok =
             Events.broadcast_stream_event(
               task_id,
               StreamEvent.new(:tool_end, %{name: "bash", status: :error, result: result})
             )

    assert_receive {:stream_event, ^task_id, %{kind: :tool_end, payload: payload}}, 500
    refute inspect(payload) =~ secret
    assert_receive {:agent_line, ^task_id, line}, 500
    refute line =~ secret
    refute RunLog.get(task_id) =~ secret
  end

  test "broadcast_agent_line also emits a :text stream event" do
    Events.subscribe()
    task_id = "evt_text_kind_#{System.unique_integer([:positive])}"

    Events.broadcast_agent_line(task_id, "hello from agent\n")

    assert_receive {:stream_event, ^task_id,
                    %{kind: :text, payload: %{text: "hello from agent\n"}}},
                   500

    assert_receive {:agent_line, ^task_id, "hello from agent\n"}, 500
    assert RunLog.get(task_id) == "hello from agent\n"
  end

  test "run markers emit stream_event without a duplicate agent_line" do
    Events.subscribe()
    task_id = "evt_marker_#{System.unique_integer([:positive])}"

    Events.broadcast_run_started(task_id, %{display_name: "Demo", role: "Code", attempt: 1})

    assert_receive {:stream_event, ^task_id, %{kind: :run_marker, payload: %{phase: :started}}},
                   500

    assert_receive {:run_started, ^task_id, _}, 500
    refute_receive {:agent_line, ^task_id, _}, 100
    assert RunLog.get(task_id) =~ "Demo (Code) started · attempt 1"
  end
end
