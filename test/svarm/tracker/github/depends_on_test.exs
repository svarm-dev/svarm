defmodule Svarm.Tracker.GitHub.DependsOnTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Svarm.Dispatch
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

  test "create_issue posts to owner/repo from config and does not KeyError" do
    assert {:ok, issue} = GitHub.create_issue(@config, %{title: "from config", body: "hello"})
    assert issue.title == "from config"
    assert [{url, json} | _] = GitHubIssuesReq.posts()
    assert url == "https://api.github.com/repos/acme/widgets/issues"
    assert json[:title] == "from config"
    refute json[:body] =~ "svarm-depends-on"
  end

  test "create_issue embeds depends_on marker when attrs include ids" do
    assert {:ok, issue} =
             GitHub.create_issue(@config, %{
               title: "blocked",
               body: "work",
               depends_on: ["I_dispatch_1"]
             })

    assert issue.depends_on == ["I_dispatch_1"]
    assert issue.body == "work"
    [{_url, json}] = GitHubIssuesReq.posts()
    assert json[:body] =~ "<!-- svarm-depends-on: I_dispatch_1 -->"
  end

  test "Dispatch GitHub path uses config on create and stores deps on the tracker" do
    {:ok, %{created_count: 2, tasks: created}} =
      Dispatch.run(
        %{
          goal: "gh-deps",
          tasks: [
            %{title: "first", body: "p1", type: "code", priority: 1, assignee: "demo"},
            %{title: "second", body: "p2", type: "code", priority: 2, assignee: "demo"}
          ]
        },
        tracker: GitHub,
        tracker_config: @config
      )

    posts = GitHubIssuesReq.posts()
    assert [_, _] = posts
    assert Enum.all?(posts, fn {url, _} -> url =~ "/repos/acme/widgets/issues" end)

    p1 = Enum.find(created, &(&1.priority == 1))
    p2 = Enum.find(created, &(&1.priority == 2))
    assert p2.depends_on == [p1.id]
    [{_url1, json1}, {_url2, json2}] = posts
    refute json1[:body] =~ "svarm-depends-on"
    assert json2[:body] =~ "<!-- svarm-depends-on: #{p1.id} -->"

    assert {:ok, listed} = GitHub.list_issues(@config, include_body: false)
    by_id = Map.new(listed, &{&1.id, &1})
    assert by_id[p1.id].depends_on == []
    assert by_id[p2.id].depends_on == [p1.id]
    assert by_id[p2.id].body == nil

    assert {:ok, fetched} = GitHub.get_issue(@config, p2.id)
    assert fetched.depends_on == [p1.id]
    assert fetched.body == "p2"
  end

  test "from_api_response parses marker onto depends_on and strips it from body" do
    gh_issue = %{
      "number" => 9,
      "node_id" => "I_nine",
      "title" => "later",
      "body" => "notes\n\n<!-- svarm-depends-on: I_one, I_two -->",
      "labels" => [],
      "assignee" => nil,
      "user" => %{"login" => "alice"},
      "created_at" => "2026-01-01T00:00:00Z",
      "repository_url" => "https://api.github.com/repos/acme/widgets",
      "state" => "open"
    }

    issue = Normalize.from_api_response(gh_issue, %{status_labels: %{}, active_states: ["todo"]})
    assert issue.depends_on == ["I_one", "I_two"]
    assert issue.body == "notes"
    refute issue.body =~ "svarm-depends-on"
  end

  test "put_depends_on_marker replaces an existing marker" do
    body = Normalize.put_depends_on_marker("hello", ["A"])
    assert body =~ "<!-- svarm-depends-on: A -->"
    replaced = Normalize.put_depends_on_marker(body, ["B", "C"])
    assert replaced == "hello\n\n<!-- svarm-depends-on: B,C -->"
    assert Normalize.depends_on_from_body(replaced) == ["B", "C"]
  end

  test "depends_on_from_body unions every marker and drops invalid ids" do
    body = """
    <!-- svarm-depends-on: -->
    notes
    <!-- svarm-depends-on: I_one, bad id, I_two -->
    """

    assert Normalize.depends_on_from_body(body) == ["I_one", "I_two"]
  end
end
