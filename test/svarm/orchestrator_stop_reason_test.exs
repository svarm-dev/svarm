defmodule Svarm.OrchestratorStopReasonTest do
  use ExUnit.Case, async: false

  alias Svarm.{KanbanBridge, Orchestrator}

  # Delegates reads/writes to the Local adapter and captures the run summary,
  # so a test can assert what the tracker adapter was handed.
  defmodule CapturingTracker do
    def list_eligible(config), do: Svarm.Tracker.Local.list_eligible(config)
    def get_issue(config, id), do: Svarm.Tracker.Local.get_issue(config, id)
    def get_issues(config, ids), do: Svarm.Tracker.Local.get_issues(config, ids)
    def list_issues(config, filters \\ []), do: Svarm.Tracker.Local.list_issues(config, filters)
    def create_issue(config, attrs), do: Svarm.Tracker.Local.create_issue(config, attrs)

    def update_status(config, id, status),
      do: Svarm.Tracker.Local.update_status(config, id, status)

    def update_attempts(config, id, n), do: Svarm.Tracker.Local.update_attempts(config, id, n)
    def claim(config, id), do: Svarm.Tracker.Local.claim(config, id)
    def delete_all(config), do: Svarm.Tracker.Local.delete_all(config)
    def capabilities, do: []

    def post_run_summary(config, id, summary) do
      send(config.owner, {:summary, id, summary})
      :ok
    end
  end

  setup do
    KanbanBridge.delete_all_tasks()
    original = :sys.get_state(Orchestrator)

    on_exit(fn ->
      :sys.replace_state(Orchestrator, fn _ -> original end)
      KanbanBridge.delete_all_tasks()
    end)

    :ok
  end

  test "a failed run reports the failed stop reason" do
    task =
      KanbanBridge.create_task(%{title: "stop reason failed", status: "todo", assignee: "cody"})

    put_run(task, max_retries: 0)

    send(Orchestrator, {:run_exit, task.id, {:error, :agent_exit}})

    assert_receive {:summary, id, %{stop_reason: :failed}}, 2_000
    assert id == task.id
  end

  test "an ok run handed back for review reports the review stop reason" do
    task =
      KanbanBridge.create_task(%{title: "stop reason review", status: "todo", assignee: "cody"})

    put_run(task, max_retries: 5)

    send(Orchestrator, {:run_exit, task.id, :ok})

    assert_receive {:summary, id, %{stop_reason: :review}}, 2_000
    assert id == task.id
  end

  test "an ok run on an already-closed ticket reports no stop reason" do
    task = KanbanBridge.create_task(%{title: "closed ticket", status: "done", assignee: "cody"})
    put_run(task, max_retries: 5)

    send(Orchestrator, {:run_exit, task.id, :ok})

    assert_receive {:summary, id, %{stop_reason: nil}}, 2_000
    assert id == task.id
  end

  defp put_run(task, opts) do
    # Capture before replace_state: the fun runs inside the orchestrator process.
    owner = self()

    :sys.replace_state(Orchestrator, fn state ->
      entry = %{
        task: task,
        pid: self(),
        mref: make_ref(),
        run_id: "run_stop_#{task.id}",
        started_mono_ms: System.monotonic_time(:millisecond),
        started_at: System.system_time(:second)
      }

      %{
        state
        | tracker: CapturingTracker,
          tracker_config: %{
            owner: owner,
            kind: :local,
            active_states: ["todo", "in_progress"],
            terminal_states: ["done", "failed", "review"]
          },
          max_retries: Keyword.fetch!(opts, :max_retries),
          running: Map.put(state.running, task.id, entry),
          claimed: MapSet.put(state.claimed, task.id),
          retry_attempts: %{},
          last_run_entries: %{}
      }
    end)
  end
end
