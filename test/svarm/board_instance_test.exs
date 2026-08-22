defmodule Svarm.BoardInstanceTest do
  use ExUnit.Case, async: false

  alias Svarm.Settings.Store
  alias Svarm.Test.GitHubListErrorReq

  setup do
    Store.delete("tracker")
    on_exit(fn -> Store.delete("tracker") end)
    :ok
  end

  test "instance_status reports local tracker and agents" do
    status = Svarm.Board.instance_status()
    assert status.tracker_kind in [:local, :github]
    assert is_binary(status.tracker_label)
    assert is_integer(status.agent_count)
    assert is_boolean(status.workflow_loaded?)
    assert is_boolean(status.approvals_auth?)
    assert is_boolean(status.empty?)
    assert status.tracker_error == nil
    assert is_boolean(status.provider_configured?)
    assert is_boolean(status.tracker_ready?)
    assert is_boolean(status.setup_complete?)
    assert status.tracker_source in ["settings", "file"]
  end

  test "list_agents returns agent config map for board UI" do
    agents = Svarm.Board.list_agents()
    assert is_map(agents)
    assert map_size(agents) >= 1
    assert agents == Svarm.AgentRunner.load_agents()
  end

  test "instance_status reuses passed agents and task_count" do
    status = Svarm.Board.instance_status(agents: %{"only" => %{}}, task_count: 3)
    assert status.agent_count == 1
    assert status.task_count == 3
    refute status.empty?
  end

  test "GitHub list_issues failure is not a healthy empty snapshot" do
    GitHubListErrorReq.install()

    assert {:error, reason} = Svarm.Board.fetch_tasks()
    assert reason.type == :rate_limit

    status = Svarm.Board.instance_status()
    refute status.empty?
    assert status.task_count == 0
    assert status.tracker_error =~ "rate limited"
    refute status.tracker_error =~ "All quiet"
  end
end
