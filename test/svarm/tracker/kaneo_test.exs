defmodule Svarm.Tracker.KaneoTest do
  use ExUnit.Case, async: false

  alias Svarm.Test.KaneoStubServer
  alias Svarm.Tracker.Kaneo

  setup do
    server = KaneoStubServer.start()

    on_exit(fn -> KaneoStubServer.stop(server) end)

    KaneoStubServer.seed(server, [
      task("t1", "todo", "Ship it"),
      task("t2", "in_progress", "In flight"),
      task("t3", "done", "Already done")
    ])

    {:ok, server: server, config: config(server)}
  end

  test "capabilities/0 opts out of CI, review, and connectivity probe" do
    assert Kaneo.capabilities() == []
  end

  describe "list_eligible/1" do
    test "returns only tasks in the configured active columns", %{config: config} do
      assert {:ok, issues} = Kaneo.list_eligible(config)

      assert issues |> Enum.map(& &1.id) |> Enum.sort() == ["t1", "t2"]
      assert Enum.all?(issues, &(&1.tracker == :kaneo))
      assert Enum.all?(issues, &(&1.status in ["todo", "in_progress"]))
    end

    test "sends the API key as x-api-key", %{config: config, server: server} do
      assert {:ok, _issues} = Kaneo.list_eligible(config)

      assert Enum.any?(KaneoStubServer.requests(server), fn request ->
               {"x-api-key", "kaneo_test_key"} in request.headers
             end)
    end
  end

  describe "get_issue/2" do
    test "returns a normalized task", %{config: config} do
      assert {:ok, issue} = Kaneo.get_issue(config, "t1")
      assert issue.id == "t1"
      assert issue.source_id == "t1"
      assert issue.title == "Ship it"
      assert issue.body == "Body t1"
      assert issue.status == "todo"
      assert issue.tenant == "proj_1"
    end

    test "missing task is :not_found", %{config: config} do
      assert {:error, :not_found} = Kaneo.get_issue(config, "missing")
    end
  end

  describe "list_issues/2" do
    test "lists every column and filters by status", %{config: config} do
      assert {:ok, all} = Kaneo.list_issues(config)
      assert length(all) == 3

      assert {:ok, done} = Kaneo.list_issues(config, status: "done")
      assert Enum.map(done, & &1.id) == ["t3"]
    end
  end

  describe "create_issue/2" do
    test "posts a task in the first active column", %{config: config, server: server} do
      assert {:ok, issue} =
               Kaneo.create_issue(config, %{title: "New", body: "Do it", priority: 2})

      assert issue.title == "New"
      assert issue.body == "Do it"
      assert issue.status == "todo"
      assert issue.priority == 2

      request = hd(KaneoStubServer.requests(server))
      assert request.method == "POST"
      assert request.path == "/api/task/proj_1"
      assert request.body["title"] == "New"
      assert request.body["description"] == "Do it"
      assert request.body["status"] == "todo"
      assert request.body["priority"] == "medium"
    end
  end

  describe "update_status/3" do
    test "moves a task to another column", %{config: config} do
      assert :ok = Kaneo.update_status(config, "t1", "done")
      assert {:ok, %{status: "done"}} = Kaneo.get_issue(config, "t1")

      assert {:ok, eligible} = Kaneo.list_eligible(config)
      refute Enum.any?(eligible, &(&1.id == "t1"))
    end
  end

  defp config(server) do
    %{
      kind: :kaneo,
      base_url: server.base_url,
      workspace: "ws_1",
      project: "proj_1",
      api_key: "kaneo_test_key",
      active_states: ["todo", "in_progress"],
      terminal_states: ["done", "failed", "review"]
    }
  end

  defp task(id, status, title) do
    %{
      "id" => id,
      "projectId" => "proj_1",
      "title" => title,
      "description" => "Body #{id}",
      "status" => status,
      "priority" => "medium",
      "userId" => nil,
      "assigneeName" => nil,
      "number" => 1,
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "labels" => []
    }
  end
end
