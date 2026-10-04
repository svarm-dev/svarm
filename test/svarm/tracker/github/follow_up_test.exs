defmodule Svarm.Tracker.GitHub.FollowUpTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Svarm.Test.GitHubIssuesReq
  alias Svarm.Tracker.GitHub
  alias Svarm.Tracker.GitHub.Normalize

  @config %{
    owner: "acme",
    repo: "widgets",
    api_key: "t",
    req: GitHubIssuesReq,
    kind: :github,
    active_states: ["todo", "in_progress"],
    terminal_states: ["done", "failed", "review"]
  }

  setup do
    GitHubIssuesReq.reset!()
    :ok
  end

  test "from_api_response parses the follow-up marker and strips it from the body" do
    gh_issue = %{
      "number" => 7,
      "node_id" => "I_seven",
      "title" => "settled",
      "body" => "notes\n\n<!-- svarm-follow-up: also fix the tests -->",
      "labels" => [],
      "assignee" => nil,
      "user" => %{"login" => "alice"},
      "created_at" => "2026-01-01T00:00:00Z",
      "repository_url" => "https://api.github.com/repos/acme/widgets",
      "state" => "open"
    }

    issue = Normalize.from_api_response(gh_issue, %{status_labels: %{}, active_states: ["todo"]})
    assert issue.follow_up == "also fix the tests"
    assert issue.body == "notes"
    refute issue.body =~ "svarm-follow-up"
  end

  test "follow_up_from_body returns nil when there is no marker" do
    assert Normalize.follow_up_from_body("plain body") == nil
    assert Normalize.follow_up_from_body(nil) == nil
    assert Normalize.follow_up_from_body("<!-- svarm-follow-up:   -->") == nil
  end

  test "put_follow_up_marker replaces or removes the marker, preserving depends_on" do
    body = Normalize.put_follow_up_marker("hello", "fix the fixture")
    assert body =~ "<!-- svarm-follow-up: fix the fixture -->"
    assert Normalize.follow_up_from_body(body) == "fix the fixture"

    replaced = Normalize.put_follow_up_marker(body, "also update docs")
    assert Normalize.follow_up_from_body(replaced) == "also update docs"
    refute replaced =~ "fix the fixture"

    cleared = Normalize.put_follow_up_marker(replaced, nil)
    assert cleared == "hello"
    assert Normalize.follow_up_from_body(cleared) == nil

    # depends_on marker is a different family — untouched by follow-up writes.
    mixed = Normalize.put_depends_on_marker(replaced, ["I_a"])
    assert Normalize.follow_up_from_body(mixed) == "also update docs"
    assert Normalize.depends_on_from_body(mixed) == ["I_a"]

    stripped = Normalize.strip_markers(mixed)
    assert stripped == "hello"
    refute stripped =~ "svarm-"
  end

  test "update_follow_up round-trips through the GitHub adapter" do
    GitHubIssuesReq.seed(%{
      "number" => 3,
      "node_id" => "I_three",
      "title" => "review card",
      "body" => "work",
      "labels" => [%{"name" => "status: review"}],
      "assignee" => nil,
      "user" => %{"login" => "svarm"},
      "created_at" => "2026-01-01T00:00:00Z",
      "repository_url" => "https://api.github.com/repos/acme/widgets",
      "state" => "open"
    })

    assert :ok = GitHub.update_follow_up(@config, "I_three", "also fix the tests")

    assert {:ok, fetched} = GitHub.get_issue(@config, "I_three")
    assert fetched.follow_up == "also fix the tests"
    assert fetched.body == "work"
    assert GitHubIssuesReq.get_issue(3)["body"] =~ "<!-- svarm-follow-up: also fix the tests -->"

    # Clear removes the marker again.
    assert :ok = GitHub.update_follow_up(@config, "I_three", nil)

    assert {:ok, refetched} = GitHub.get_issue(@config, "I_three")
    assert refetched.follow_up == nil
    refute GitHubIssuesReq.get_issue(3)["body"] =~ "svarm-follow-up"
  end

  test "update_follow_up keeps an existing depends_on marker" do
    GitHubIssuesReq.seed(%{
      "number" => 4,
      "node_id" => "I_four",
      "title" => "blocked",
      "body" => "work\n\n<!-- svarm-depends-on: I_a -->",
      "labels" => [%{"name" => "status: review"}],
      "assignee" => nil,
      "user" => %{"login" => "svarm"},
      "created_at" => "2026-01-01T00:00:00Z",
      "repository_url" => "https://api.github.com/repos/acme/widgets",
      "state" => "open"
    })

    assert :ok = GitHub.update_follow_up(@config, "I_four", "also fix the tests")

    raw = GitHubIssuesReq.get_issue(4)["body"]
    assert Normalize.depends_on_from_body(raw) == ["I_a"]
    assert Normalize.follow_up_from_body(raw) == "also fix the tests"

    assert :ok = GitHub.update_depends_on(@config, "I_four", ["I_b"])
    rewritten = GitHubIssuesReq.get_issue(4)["body"]
    assert Normalize.depends_on_from_body(rewritten) == ["I_b"]
    assert Normalize.follow_up_from_body(rewritten) == "also fix the tests"
  end

  test "follow-up text containing an HTML comment closer round-trips" do
    note = "stop --> then continue & retry"

    GitHubIssuesReq.seed(%{
      "number" => 5,
      "node_id" => "I_five",
      "title" => "review card",
      "body" => "work",
      "labels" => [%{"name" => "status: review"}],
      "assignee" => nil,
      "user" => %{"login" => "svarm"},
      "created_at" => "2026-01-01T00:00:00Z",
      "repository_url" => "https://api.github.com/repos/acme/widgets",
      "state" => "open"
    })

    assert :ok = GitHub.update_follow_up(@config, "I_five", note)
    raw = GitHubIssuesReq.get_issue(5)["body"]
    refute raw =~ "stop -->"
    assert {:ok, fetched} = GitHub.get_issue(@config, "I_five")
    assert fetched.follow_up == note
    assert fetched.body == "work"
  end

  test "update_status todo reopens a closed failed issue" do
    GitHubIssuesReq.seed(%{
      "number" => 6,
      "node_id" => "I_six",
      "title" => "failed card",
      "body" => "work",
      "labels" => [%{"name" => "status: failed"}],
      "assignee" => nil,
      "user" => %{"login" => "svarm"},
      "created_at" => "2026-01-01T00:00:00Z",
      "repository_url" => "https://api.github.com/repos/acme/widgets",
      "state" => "closed"
    })

    assert :ok = GitHub.update_status(@config, "I_six", "todo")
    stored = GitHubIssuesReq.get_issue(6)
    assert stored["state"] == "open"
    assert {:ok, issues} = GitHub.list_eligible(@config)
    assert Enum.any?(issues, &(&1.id == "I_six"))
  end
end
