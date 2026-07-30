defmodule Svarm.DispatchTest do
  use ExUnit.Case, async: false

  alias Svarm.{Dispatch, KanbanBridge}

  test "routes tasks through ProfileRouter when assignee is omitted" do
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

  test "keeps an explicit assignee (demo seed path)" do
    {:ok, %{tasks: [created]}} =
      Dispatch.run(%{
        goal: "demo",
        tasks: [
          %{
            title: "Demo: clarify scope for research",
            body: "research and code notes",
            type: "research",
            priority: 1,
            assignee: "demo_research"
          }
        ]
      })

    assert created.assignee == "demo_research"
    assert %{assignee: "demo_research"} = KanbanBridge.get_task(created.id)
  end
end
