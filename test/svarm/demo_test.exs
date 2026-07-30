defmodule Svarm.DemoTest do
  use ExUnit.Case, async: false

  alias Svarm.{Demo, KanbanBridge}

  test "seed creates demo tasks on the board" do
    KanbanBridge.delete_all_tasks()
    assert {:ok, count} = Demo.seed("test goal")
    assert count == 3
    tasks = KanbanBridge.list_tasks([])
    assert Enum.any?(tasks, &String.contains?(&1.title, "Demo:"))

    assert Enum.map(tasks, & &1.assignee) |> Enum.sort() ==
             ["demo_code", "demo_docs", "demo_research"]
  end

  test "seed clears previous tickets" do
    KanbanBridge.delete_all_tasks()
    assert {:ok, 3} = Demo.seed("first")
    assert match?([_, _, _], KanbanBridge.list_tasks([]))
    assert {:ok, 3} = Demo.seed("second")
    tasks = KanbanBridge.list_tasks([])
    assert match?([_, _, _], tasks)

    assert Enum.map(tasks, & &1.assignee) |> Enum.sort() ==
             ["demo_code", "demo_docs", "demo_research"]
  end

  test "seed_if_empty skips when board has tasks" do
    assert {:ok, _} = Demo.seed("first")
    assert :already_has_tasks = Demo.seed_if_empty("second")
  end

  test "seed applies approval overlay so demo_code is gated" do
    Application.delete_env(:svarm, :approval_overlay)
    assert {:ok, _} = Demo.seed("gate me")

    overlay = Application.get_env(:svarm, :approval_overlay)
    assert overlay.mode == :untrusted
    assert MapSet.member?(overlay.trusted_assignees, "demo_research")
    refute MapSet.member?(overlay.trusted_assignees, "demo_code")

    cfg = Map.merge(%{mode: :off, trusted_assignees: MapSet.new()}, overlay)
    agents = %{"demo_research" => %{}, "demo_code" => %{}, "demo_docs" => %{}}

    refute Svarm.Approval.required?(
             cfg,
             %{status: "todo", assignee: "demo_research", title: "r", body: ""},
             agents
           )

    assert Svarm.Approval.required?(
             cfg,
             %{status: "todo", assignee: "demo_code", title: "c", body: ""},
             agents
           )
  end

  test "routes_enabled? follows demo_routes or dev_routes" do
    prev_demo = Application.get_env(:svarm, :demo_routes)
    prev_dev = Application.get_env(:svarm, :dev_routes)

    try do
      Application.put_env(:svarm, :demo_routes, false)
      Application.put_env(:svarm, :dev_routes, false)
      refute Demo.routes_enabled?()

      Application.put_env(:svarm, :demo_routes, true)
      assert Demo.routes_enabled?()
    after
      if prev_demo == nil,
        do: Application.delete_env(:svarm, :demo_routes),
        else: Application.put_env(:svarm, :demo_routes, prev_demo)

      Application.put_env(:svarm, :dev_routes, prev_dev)
    end
  end
end
