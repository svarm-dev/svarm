defmodule Svarm.Runner.CliFollowUpTest do
  use ExUnit.Case, async: false

  alias Svarm.{Events, Issue}
  alias Svarm.Runner.Cli

  # Minimal tracker double for the runner (only terminal update_status is used).
  defmodule StubTracker do
    def update_status(config, id, status) do
      Agent.update(config.statuses, &[{id, status} | &1])
      :ok
    end
  end

  setup do
    {:ok, statuses} = Agent.start_link(fn -> [] end)

    workspace_root =
      Path.join(System.tmp_dir!(), "svarm_follow_up_cli_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    :ok = Events.subscribe()

    on_exit(fn ->
      if Process.alive?(statuses), do: Agent.stop(statuses)
      File.rm_rf(workspace_root)
    end)

    %{workspace_root: workspace_root, statuses: statuses}
  end

  test "the CLI dispatch prompt carries the queued follow-up once", %{
    workspace_root: root,
    statuses: statuses
  } do
    id = "sva_follow_up_prompt"

    task = %Issue{
      id: id,
      source_id: id,
      title: "settled",
      body: "do it",
      type: "code",
      assignee: "agent",
      status: "in_progress",
      attempts: 0,
      tenant: "test",
      follow_up: "also fix the tests"
    }

    # Echoes its prompt argument to stdout; the runner streams it into the log.
    cfg = %{
      command: "/bin/echo",
      args: [],
      env: %{},
      display_name: "Echo",
      adapter: "cli",
      provider: "test",
      model: "fake"
    }

    assert :ok =
             Cli.run(task, cfg,
               workspace_root: root,
               tracker: StubTracker,
               tracker_config: %{statuses: statuses},
               run_id: "run_fu"
             )

    log = Svarm.RunLog.get(id)
    assert log =~ "Operator follow-up for this run:"
    assert log =~ "also fix the tests"
    # Included exactly once — never repeated for the same note.
    assert match?([_, _], String.split(log, "Operator follow-up for this run:"))
  end

  test "no follow-up queued → prompt has no follow-up block", %{
    workspace_root: root,
    statuses: statuses
  } do
    id = "sva_follow_up_absent"

    task = %Issue{
      id: id,
      source_id: id,
      title: "plain",
      body: "do it",
      type: "code",
      assignee: "agent",
      status: "in_progress",
      attempts: 0,
      tenant: "test"
    }

    cfg = %{
      command: "/bin/echo",
      args: [],
      env: %{},
      display_name: "Echo",
      adapter: "cli",
      provider: "test",
      model: "fake"
    }

    assert :ok =
             Cli.run(task, cfg,
               workspace_root: root,
               tracker: StubTracker,
               tracker_config: %{statuses: statuses},
               run_id: "run_fu_absent"
             )

    refute Svarm.RunLog.get(id) =~ "Operator follow-up"
  end
end
