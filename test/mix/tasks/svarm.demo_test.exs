defmodule Mix.Tasks.Svarm.DemoTest do
  use ExUnit.Case, async: false

  alias Svarm.{KanbanBridge, Settings, Tracker}

  setup do
    KanbanBridge.delete_all_tasks()
    Settings.Store.delete("tracker")

    on_exit(fn ->
      KanbanBridge.delete_all_tasks()
      Settings.Store.delete("tracker")
    end)

    :ok
  end

  test "watch loop lists the local board when Settings overlay is GitHub" do
    assert {:ok, _} =
             Settings.put_tracker(%{
               "kind" => "github",
               "owner" => "acme",
               "repo" => "widgets",
               "api_key" => "ghp_test",
               "auth" => "token"
             })

    KanbanBridge.create_task(%{
      title: "isolated demo ticket",
      status: "todo",
      assignee: "demo_research"
    })

    assert {Tracker.GitHub, _} = Tracker.Resolve.adapter_and_config()

    assert {:ok, issues} = Mix.Tasks.Svarm.Demo.list_issues()
    assert Enum.any?(issues, &(&1.title == "isolated demo ticket"))
  end
end
