defmodule Svarm.Runner.CliTest do
  use ExUnit.Case, async: false

  alias Svarm.{AgentRunner, Events, Issue}
  alias Svarm.Runner.Cli

  @fake Path.expand("../../support/fake_cli_agent.sh", __DIR__)
  @demo_script Path.join(:code.priv_dir(:svarm), "demo_agent.sh")

  defmodule StubTracker do
    def update_status(config, id, status) do
      Agent.update(config.statuses, &[{id, status} | &1])
      :ok
    end
  end

  setup do
    {:ok, statuses} = Agent.start_link(fn -> [] end)

    workspace_root =
      Path.join(System.tmp_dir!(), "svarm_cli_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    :ok = Events.subscribe()

    on_exit(fn ->
      if Process.alive?(statuses), do: Agent.stop(statuses)
      File.rm_rf(workspace_root)
    end)

    %{workspace_root: workspace_root, statuses: statuses}
  end

  defp task(id, assignee \\ "demo") do
    %Issue{
      id: id,
      source_id: id,
      title: "CLI fixture task",
      body: "do the thing",
      type: "code",
      assignee: assignee,
      status: "in_progress",
      attempts: 0,
      tenant: "test"
    }
  end

  defp agent_config(mode) do
    %{
      command: "sh",
      args: [@fake, mode],
      env: %{},
      display_name: "FakeCli",
      adapter: "cli",
      provider: "test",
      model: "fake"
    }
  end

  defp run_opts(workspace_root, statuses) do
    [
      workspace_root: workspace_root,
      tracker: StubTracker,
      tracker_config: %{statuses: statuses},
      run_id: "run_cli_#{System.unique_integer([:positive])}"
    ]
  end

  defp last_status(statuses, id) do
    Agent.get(statuses, fn list ->
      Enum.find_value(list, fn
        {^id, status} -> status
        _ -> nil
      end)
    end)
  end

  defp assert_agent_line(task_id, pattern, timeout \\ 2_000) do
    assert_receive {:agent_line, ^task_id, line}, timeout

    if line =~ pattern do
      line
    else
      assert_agent_line(task_id, pattern, timeout)
    end
  end

  test "fake peer is executable" do
    assert File.regular?(@fake)
    assert Bitwise.band(File.stat!(@fake).mode, 0o111) != 0
  end

  test "demo agent from agents.toml expands DEMO_SCRIPT path" do
    agents = AgentRunner.load_agents()
    cfg = AgentRunner.resolve!("demo", agents)

    assert cfg.command == "sh"
    assert hd(cfg.args) == @demo_script
    assert File.regular?(@demo_script)
    assert Bitwise.band(File.stat!(@demo_script).mode, 0o111) != 0
  end

  test "happy path: start + exit 0 → :ok and review status", %{
    workspace_root: root,
    statuses: statuses
  } do
    id = "sva_cli_ok"
    assert :ok = Cli.run(task(id), agent_config("ok"), run_opts(root, statuses))
    assert last_status(statuses, id) == "review"
    assert_agent_line(id, "fake-cli: ok")

    log_path = Path.join([root, id, "run.log"])
    assert File.exists?(log_path)
    assert File.read!(log_path) =~ "fake-cli: ok"
  end

  test "non-zero exit → error and failed status", %{
    workspace_root: root,
    statuses: statuses
  } do
    id = "sva_cli_fail"

    assert {:error, {:agent_exit, 1, out}} =
             Cli.run(task(id), agent_config("fail"), run_opts(root, statuses))

    assert out =~ "fake-cli: fail"
    assert last_status(statuses, id) == "failed"
    assert_agent_line(id, "fake-cli: fail")
  end

  test "missing executable → exit -1 and failed status", %{
    workspace_root: root,
    statuses: statuses
  } do
    id = "sva_cli_missing"

    cfg = %{
      command: "definitely-not-a-real-svarm-agent-bin",
      args: [],
      env: %{},
      display_name: "Missing",
      adapter: "cli",
      provider: "test",
      model: "none"
    }

    assert {:error, {:agent_exit, -1, out}} =
             Cli.run(task(id), cfg, run_opts(root, statuses))

    assert out =~ "executable not found"
    assert last_status(statuses, id) == "failed"
    assert_agent_line(id, "executable not found")
  end

  test "load_agents and resolve! match AgentRunner facade" do
    from_cli = Cli.load_agents()
    from_facade = AgentRunner.load_agents()

    # Facade may merge Settings overrides; base keys and commands must still match.
    assert Map.keys(from_cli) -- Map.keys(from_facade) == []
    assert from_cli["demo"].command == from_facade["demo"].command

    assert Cli.resolve!("demo_code", from_cli).args ==
             AgentRunner.resolve!("demo_code", from_facade).args
  end
end
