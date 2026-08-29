defmodule Svarm.DispatchTest do
  use ExUnit.Case, async: false

  alias Svarm.{Dispatch, KanbanBridge}
  alias Svarm.Test.FakeTracker

  defmodule CreateFailTracker do
    def create_issue(_config, _attrs), do: {:error, :auth_failure}
    def update_depends_on(_config, _id, _depends_on), do: :ok
  end

  setup do
    KanbanBridge.delete_all_tasks()
    FakeTracker.setup()
    :ok
  end

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

  test "local dispatch wires depends_on through KanbanBridge" do
    {:ok, %{tasks: created}} =
      Dispatch.run(%{
        goal: "local-deps",
        tasks: [
          %{title: "first", body: "p1", type: "code", priority: 1, assignee: "demo"},
          %{title: "second", body: "p2", type: "code", priority: 2, assignee: "demo"}
        ]
      })

    p1 = Enum.find(created, &(&1.priority == 1))
    p2 = Enum.find(created, &(&1.priority == 2))
    assert p1.id
    assert p2.depends_on == [p1.id]
    assert %{depends_on: deps} = KanbanBridge.get_task(p2.id)
    assert deps == [p1.id]
    assert KanbanBridge.get_task(p1.id).depends_on == []

    {:ok, listed} = Svarm.Tracker.Local.list_issues(%{}, include_body: false)
    listed_p2 = Enum.find(listed, &(&1.id == p2.id))
    assert listed_p2.depends_on == [p1.id]
  end

  test "fake adapter create_issue receives resolved tracker config, not empty map" do
    config = %{owner: "acme", repo: "widgets", kind: :github}

    {:ok, %{tasks: created}} =
      Dispatch.run(
        %{
          goal: "gh-config",
          tasks: [
            %{title: "first", body: "p1", type: "code", priority: 1, assignee: "demo"},
            %{title: "second", body: "p2", type: "code", priority: 2, assignee: "demo"}
          ]
        },
        tracker: FakeTracker,
        tracker_config: config
      )

    configs = FakeTracker.create_configs()
    assert [_, _] = configs
    assert Enum.all?(configs, &(&1.owner == "acme" and &1.repo == "widgets"))
    refute Enum.any?(configs, &(&1 == %{}))
    assert FakeTracker.last_create_config() == config

    p1 = Enum.find(created, &(&1.priority == 1))
    p2 = Enum.find(created, &(&1.priority == 2))
    assert p2.depends_on == [p1.id]
    assert FakeTracker.get(p2.id).depends_on == [p1.id]
  end

  test "omitted or zero priority does not gate priority-1 work" do
    {:ok, %{tasks: created}} =
      Dispatch.run(%{
        goal: "omit-pri",
        tasks: [
          %{title: "no-pri", body: "dropped", type: "code", assignee: "demo"},
          %{title: "zero", body: "explicit-0", type: "code", priority: 0, assignee: "demo"},
          %{title: "first", body: "p1", type: "code", priority: 1, assignee: "demo"},
          %{title: "second", body: "p2", type: "code", priority: 2, assignee: "demo"}
        ]
      })

    wave1 = Enum.filter(created, &(&1.priority == 1))
    p2 = Enum.find(created, &(&1.title == "second"))

    assert length(wave1) == 3
    assert Enum.all?(wave1, &(&1.depends_on == []))
    assert Enum.sort(p2.depends_on) == Enum.sort(Enum.map(wave1, & &1.id))
    refute Enum.any?(created, &(&1.priority == 0))
  end

  test "returns tagged error when create_issue fails" do
    assert {:error, :auth_failure} =
             Dispatch.run(
               %{
                 goal: "fail",
                 tasks: [%{title: "t", body: "b", type: "code", priority: 1, assignee: "demo"}]
               },
               tracker: CreateFailTracker,
               tracker_config: %{owner: "acme", repo: "widgets"}
             )
  end
end
