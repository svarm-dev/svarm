defmodule Svarm.DispatchTest do
  use ExUnit.Case, async: false

  alias Svarm.{Dispatch, KanbanBridge}

  test "routes tasks through ProfileRouter and creates them in kanban" do
    {:ok, %{tasks: [created]}} =
      Dispatch.run(%{
        goal: "test",
        tasks: [
          %{title: "infra thing", body: "docker", type: "infra", priority: 1}
        ]
      })

    # Assignee is resolved by ProfileRouter (keyword match → default agent)
    assert is_binary(created.assignee)
    assert %{assignee: assignee} = KanbanBridge.get_task(created.id)
    assert is_binary(assignee)
  end
end
