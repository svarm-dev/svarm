defmodule Svarm.DemoTest do
  use ExUnit.Case, async: false

  alias Svarm.{Demo, KanbanBridge, Orchestrator, Settings}

  setup do
    KanbanBridge.delete_all_tasks()
    Settings.Store.delete("tracker")
    Application.delete_env(:svarm, :approval_overlay)

    # Demo.seed mutates process-global orchestrator knobs (2s poll, max 1).
    # Capture and restore so later suite modules are not stuck on a fast tick.
    prev_poll = Application.get_env(:svarm, :orchestrator_poll_interval_ms)
    prev_max = Application.get_env(:svarm, :orchestrator_max_concurrent)

    on_exit(fn ->
      Settings.Store.delete("tracker")
      Application.delete_env(:svarm, :approval_overlay)
      restore_env(:orchestrator_poll_interval_ms, prev_poll)
      restore_env(:orchestrator_max_concurrent, prev_max)

      if Process.whereis(Orchestrator) do
        _ = Orchestrator.reload_config()
      end
    end)

    :ok
  end

  test "seed creates demo tasks on the board" do
    assert {:ok, count} = Demo.seed("test goal")
    assert count == 3
    tasks = KanbanBridge.list_tasks([])
    assert Enum.any?(tasks, &String.contains?(&1.title, "Demo:"))

    assert Enum.map(tasks, & &1.assignee) |> Enum.sort() ==
             ["demo_code", "demo_docs", "demo_research"]
  end

  test "seed clears previous tickets" do
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

  test "leftover approval_overlay is ignored when demo profile flags are off" do
    prev_seed = Application.get_env(:svarm, :seed_demo_on_boot)
    prev_demo = Application.get_env(:svarm, :demo_routes)
    prev_dev = Application.get_env(:svarm, :dev_routes)

    try do
      Application.put_env(:svarm, :seed_demo_on_boot, false)
      Application.put_env(:svarm, :demo_routes, false)
      Application.put_env(:svarm, :dev_routes, false)
      refute Demo.demo_profile_active?()

      # Distinctive stale overlay — if merged, mode would become :all and trust only this name.
      Application.put_env(:svarm, :approval_overlay, %{
        mode: :all,
        trusted_assignees: MapSet.new(["only_from_overlay"])
      })

      assert {:ok, _} = Orchestrator.reload_config()
      status = Orchestrator.status()
      # WORKFLOW template policy only (mode untrusted; no overlay merge)
      assert status.approval.mode == :untrusted
      refute MapSet.member?(status.approval.trusted_assignees, "only_from_overlay")
    after
      restore_env(:seed_demo_on_boot, prev_seed)
      restore_env(:demo_routes, prev_demo)
      restore_env(:dev_routes, prev_dev)
      # Restore test default so later tests see demo_profile_active?
      Application.put_env(:svarm, :dev_routes, true)
    end
  end

  test "seed refuses when active tracker is GitHub" do
    assert {:ok, _} =
             Settings.put_tracker(%{
               "kind" => "github",
               "owner" => "acme",
               "repo" => "widgets",
               "api_key" => "ghp_test",
               "auth" => "token"
             })

    KanbanBridge.create_task(%{
      title: "keep me",
      status: "todo",
      assignee: "demo_research"
    })

    assert {:error, :github_tracker} = Demo.seed("should refuse")
    # Board not wiped
    assert [%{title: "keep me"}] = KanbanBridge.list_tasks([])
  end

  test "seed refuses when board has non-demo assignees" do
    KanbanBridge.create_task(%{
      title: "real work",
      status: "todo",
      assignee: "default"
    })

    assert {:error, :non_demo_tasks} = Demo.seed("should refuse")
    assert [%{title: "real work"}] = KanbanBridge.list_tasks([])
  end

  test "seed refuses blank or nil assignees as non-demo without wipe" do
    KanbanBridge.create_task(%{
      title: "orphan nil",
      status: "todo",
      assignee: nil
    })

    assert {:error, :non_demo_tasks} = Demo.seed("should refuse")
    assert [%{title: "orphan nil"}] = KanbanBridge.list_tasks([])

    KanbanBridge.delete_all_tasks()

    KanbanBridge.create_task(%{
      title: "orphan blank",
      status: "todo",
      assignee: ""
    })

    assert {:error, :non_demo_tasks} = Demo.seed("should refuse")
    assert [%{title: "orphan blank"}] = KanbanBridge.list_tasks([])
  end

  test "seed_if_empty refuses when active tracker is GitHub" do
    assert {:ok, _} =
             Settings.put_tracker(%{
               "kind" => "github",
               "owner" => "acme",
               "repo" => "widgets",
               "api_key" => "ghp_test",
               "auth" => "token"
             })

    assert {:error, :github_tracker} = Demo.seed_if_empty("should refuse")
  end

  test "seed reloads orchestrator approval with overlay (demo_code gated, no default)" do
    assert Demo.demo_profile_active?()
    assert {:ok, _} = Demo.seed("overlay sync")

    overlay = Application.get_env(:svarm, :approval_overlay)
    assert overlay.mode == :untrusted
    assert MapSet.member?(overlay.trusted_assignees, "demo_research")
    assert MapSet.member?(overlay.trusted_assignees, "demo_docs")
    refute MapSet.member?(overlay.trusted_assignees, "demo_code")
    refute MapSet.member?(overlay.trusted_assignees, "default")

    status = Orchestrator.status()
    assert status.approval.mode == :untrusted
    assert MapSet.member?(status.approval.trusted_assignees, "demo_research")
    refute MapSet.member?(status.approval.trusted_assignees, "demo_code")
    refute MapSet.member?(status.approval.trusted_assignees, "default")
  end

  test "seed allows re-seed when board has only demo assignees" do
    KanbanBridge.create_task(%{
      title: "old demo",
      status: "todo",
      assignee: "demo_research"
    })

    assert {:ok, 3} = Demo.seed("re-seed ok")
    tasks = KanbanBridge.list_tasks([])
    assert match?([_, _, _], tasks)

    assert Enum.map(tasks, & &1.assignee) |> Enum.sort() ==
             ["demo_code", "demo_docs", "demo_research"]
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
      restore_env(:demo_routes, prev_demo)
      Application.put_env(:svarm, :dev_routes, prev_dev || true)
    end
  end

  test "flash_error covers seed refusal reasons" do
    assert Demo.flash_error(:github_tracker) =~ "GitHub"
    assert Demo.flash_error(:non_demo_tasks) =~ "non-demo"
    assert Demo.flash_error(:other) =~ "other"
  end

  defp restore_env(key, nil), do: Application.delete_env(:svarm, key)
  defp restore_env(key, val), do: Application.put_env(:svarm, key, val)
end
