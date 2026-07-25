defmodule Svarm.BoardInstanceTest do
  use ExUnit.Case, async: false

  test "instance_status reports local tracker and agents" do
    status = Svarm.Board.instance_status()
    assert status.tracker_kind in [:local, :github]
    assert is_binary(status.tracker_label)
    assert is_integer(status.agent_count)
    assert is_boolean(status.workflow_loaded?)
    assert is_boolean(status.approvals_auth?)
    assert is_boolean(status.empty?)
    assert is_boolean(status.provider_configured?)
    assert is_boolean(status.tracker_ready?)
    assert is_boolean(status.setup_complete?)
    assert status.tracker_source in ["settings", "file"]
  end
end
