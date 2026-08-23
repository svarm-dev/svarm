defmodule Svarm.Tracker.GitHub.PendingApprovalTest do
  use ExUnit.Case, async: false

  alias Svarm.Approval
  alias Svarm.Tracker.GitHub
  alias Svarm.Workflow.Config

  defmodule StubReq do
    def get(url, opts) do
      send(self(), {:http_get, url, Keyword.take(opts, [:params, :json])})

      if single_issue_url?(url) do
        Process.get(:github_issue_response)
      else
        Process.get(:github_list_response)
      end
    end

    def patch(url, opts) do
      send(self(), {:http_patch, url, Keyword.take(opts, [:params, :json])})
      Process.get(:github_patch_response, {:ok, %{status: 200, body: %{}}})
    end

    defp single_issue_url?(url) do
      match?({_n, ""}, Integer.parse(Path.basename(url)))
    end
  end

  @config %{
    owner: "acme",
    repo: "widgets",
    api_key: "t",
    req: StubReq,
    kind: :github,
    active_states: ["todo", "in_progress"]
  }

  setup do
    Approval.__clear_tracker_override__()

    on_exit(fn ->
      Approval.__clear_tracker_override__()
    end)

    :ok
  end

  describe "update_status/3 pending_approval" do
    test "PATCHes status: pending-approval and strips other status labels" do
      stub_issue(
        gh_issue(%{
          "labels" => [
            %{"name" => "status: in-progress"},
            %{"name" => "ai-task"}
          ]
        })
      )

      assert :ok = GitHub.update_status(@config, "42", "pending_approval")

      assert_received {:http_patch, url, opts}
      assert url =~ "/repos/acme/widgets/issues/42"
      labels = opts[:json][:labels]
      assert "status: pending-approval" in labels
      refute "status: in-progress" in labels
      assert "ai-task" in labels
      assert Enum.count(labels, &String.starts_with?(&1, "status: ")) == 1
    end

    test "budget hold reuses pending_approval — no extra status label" do
      stub_issue(gh_issue(%{"labels" => [%{"name" => "ai-task"}]}))

      assert :ok = GitHub.update_status(@config, "42", "pending_approval")

      assert_received {:http_patch, _url, opts}
      labels = opts[:json][:labels]
      status_labels = Enum.filter(labels, &String.starts_with?(&1, "status: "))
      assert status_labels == ["status: pending-approval"]
      refute "status: over-budget" in labels
      refute "budget_overage" in labels
    end

    test "custom reverse_labels are used for the PATCH" do
      stub_issue(gh_issue(%{"labels" => [%{"name" => "status: in-progress"}]}))

      config =
        Map.put(@config, :reverse_labels, %{
          "pending_approval" => "gate: wait"
        })

      assert :ok = GitHub.update_status(config, "42", "pending_approval")

      assert_received {:http_patch, _url, opts}
      labels = opts[:json][:labels]
      assert "gate: wait" in labels
      refute "status: pending-approval" in labels
      refute "status: in-progress" in labels
    end

    test "reverse-only override still strips leftover default status labels on todo" do
      stub_issue(
        gh_issue(%{
          "labels" => [
            %{"name" => "status: pending-approval"},
            %{"name" => "ai-task"}
          ]
        })
      )

      config = Map.put(@config, :reverse_labels, %{"pending_approval" => "gate: wait"})
      assert :ok = GitHub.update_status(config, "42", "todo")

      assert_received {:http_patch, _url, opts}
      labels = opts[:json][:labels]
      refute "status: pending-approval" in labels
      refute "gate: wait" in labels
      assert "ai-task" in labels
    end
  end

  describe "Normalize.map_status / from_api_response" do
    test "reads status: pending-approval back as pending_approval via get_issue" do
      payload = gh_issue(%{"labels" => [%{"name" => "status: pending-approval"}]})
      stub_issue(payload)

      assert {:ok, issue} = GitHub.get_issue(@config, "42")
      assert issue.status == "pending_approval"
      assert "status: pending-approval" in issue.labels
    end

    test "reverse-only override maps the custom label without a status_labels entry" do
      payload = gh_issue(%{"labels" => [%{"name" => "gate: wait"}]})
      stub_issue(payload)
      config = Map.put(@config, :reverse_labels, %{"pending_approval" => "gate: wait"})

      assert {:ok, issue} = GitHub.get_issue(config, "42")
      assert issue.status == "pending_approval"
    end

    test "reverse-only override still reads leftover default pending-approval labels" do
      payload = gh_issue(%{"labels" => [%{"name" => "status: pending-approval"}]})
      stub_issue(payload)
      config = Map.put(@config, :reverse_labels, %{"pending_approval" => "gate: wait"})

      assert {:ok, issue} = GitHub.get_issue(config, "42")
      assert issue.status == "pending_approval"
    end
  end

  describe "list_issues/2 status: pending_approval" do
    test "queries the mapped label, not a naive status: pending_approval string" do
      payload = gh_issue(%{"labels" => [%{"name" => "status: pending-approval"}]})
      stub_list([payload])

      assert {:ok, [issue]} = GitHub.list_issues(@config, status: "pending_approval")
      assert issue.status == "pending_approval"
      assert issue.source_id == "42"

      assert_received {:http_get, url, opts}
      assert url =~ "/repos/acme/widgets/issues"
      refute String.contains?(url, "/issues/")
      assert opts[:params][:labels] == "status: pending-approval"
      refute opts[:params][:labels] == "status: pending_approval"
    end

    test "custom reverse_labels change the list query" do
      stub_list([gh_issue(%{"labels" => [%{"name" => "gate: wait"}]})])

      config =
        Map.merge(@config, %{
          reverse_labels: %{"pending_approval" => "gate: wait"},
          status_labels: %{"gate: wait" => "pending_approval"}
        })

      assert {:ok, [issue]} = GitHub.list_issues(config, status: "pending_approval")
      assert issue.status == "pending_approval"

      assert_received {:http_get, _url, opts}
      assert opts[:params][:labels] == "gate: wait"
    end

    test "reverse-only override is enough for list_issues to read pending_approval" do
      stub_list([gh_issue(%{"labels" => [%{"name" => "gate: wait"}]})])
      config = Map.put(@config, :reverse_labels, %{"pending_approval" => "gate: wait"})

      assert {:ok, [issue]} = GitHub.list_issues(config, status: "pending_approval")
      assert issue.status == "pending_approval"

      assert_received {:http_get, _url, opts}
      assert opts[:params][:labels] == "gate: wait"
    end

    test "WORKFLOW-parsed maps are honored by list_issues" do
      cfg =
        Config.tracker_config(%{
          "tracker" => %{
            "kind" => "github",
            "owner" => "acme",
            "repo" => "widgets",
            "status_labels" => %{"gate: wait" => "pending_approval"},
            "reverse_labels" => %{"pending_approval" => "gate: wait"}
          }
        })

      config = Map.merge(cfg, %{req: StubReq, api_key: "t"})
      stub_list([gh_issue(%{"labels" => [%{"name" => "gate: wait"}]})])

      assert {:ok, [issue]} = GitHub.list_issues(config, status: "pending_approval")
      assert issue.status == "pending_approval"

      assert_received {:http_get, _url, opts}
      assert opts[:params][:labels] == "gate: wait"
    end
  end

  describe "Approval against GitHub adapter (HTTP stub)" do
    setup do
      Approval.__override_tracker__(GitHub, @config)
      :ok
    end

    test "list_pending returns GitHub issues labeled pending-approval" do
      payload = gh_issue(%{"labels" => [%{"name" => "status: pending-approval"}]})
      stub_list([payload])

      pending = Approval.list_pending()
      assert Enum.map(pending, & &1.source_id) == ["42"]
      assert hd(pending).status == "pending_approval"

      assert_received {:http_get, _url, opts}
      assert opts[:params][:labels] == "status: pending-approval"
    end

    test "approve of a numeric GitHub issue id strips the pending-approval label" do
      stub_issue(
        gh_issue(%{"labels" => [%{"name" => "status: pending-approval"}, %{"name" => "ai-task"}]})
      )

      assert :ok = Approval.approve("42")
      assert_received {:http_patch, url, opts}
      assert url =~ "/issues/42"
      refute "status: pending-approval" in opts[:json][:labels]
      assert "ai-task" in opts[:json][:labels]
    end

    test "approve of a node_id still works after the issue leaves the eligible set" do
      payload =
        gh_issue(%{
          "labels" => [%{"name" => "status: pending-approval"}, %{"name" => "ai-task"}]
        })

      stub_list([payload])

      assert {:ok, []} = GitHub.list_eligible(@config)
      assert :ok = Approval.approve("I_42")
      assert_received {:http_patch, url, opts}
      assert url =~ "/issues/42"
      refute "status: pending-approval" in opts[:json][:labels]
      assert "ai-task" in opts[:json][:labels]
    end

    test "reject of a numeric GitHub issue id sets status: failed" do
      stub_issue(gh_issue(%{"labels" => [%{"name" => "status: pending-approval"}]}))

      assert :ok = Approval.reject("42")
      assert_received {:http_patch, url, opts}
      assert url =~ "/issues/42"
      assert "status: failed" in opts[:json][:labels]
      refute "status: pending-approval" in opts[:json][:labels]
      assert opts[:json][:state] == "closed"
    end
  end

  defp stub_issue(body) do
    Process.put(:github_issue_response, {:ok, %{status: 200, body: body}})
  end

  defp stub_list(issues) do
    Process.put(:github_list_response, {:ok, %{status: 200, body: issues}})
  end

  defp gh_issue(overrides) do
    Map.merge(
      %{
        "number" => 42,
        "node_id" => "I_42",
        "title" => "Gate me",
        "body" => "",
        "labels" => [],
        "assignee" => nil,
        "user" => %{"login" => "alice"},
        "created_at" => "2026-01-01T00:00:00Z",
        "repository_url" => "https://api.github.com/repos/acme/widgets",
        "state" => "open"
      },
      overrides
    )
  end
end
