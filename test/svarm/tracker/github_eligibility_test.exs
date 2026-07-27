defmodule Svarm.Tracker.GitHub.EligibilityTest do
  use ExUnit.Case, async: true

  alias Svarm.Issue
  alias Svarm.Tracker.GitHub.Eligibility

  @config %{
    active_states: ["todo", "in_progress"],
    required_labels: ["ai-task"],
    status_labels: %{
      "status: in-progress" => "in_progress",
      "status: done" => "done",
      "status: failed" => "failed",
      "status: review" => "review"
    }
  }

  defp issue(attrs) do
    defaults = %{
      id: "gh_1",
      source_id: "1",
      title: "t",
      body: "",
      type: "code",
      assignee: nil,
      status: "todo",
      priority: 0,
      attempts: 0,
      created_by: "u",
      created_at: 0,
      tenant: "svarm-dev",
      labels: ["ai-task"],
      depends_on: [],
      tracker: :github,
      raw: %{"state" => "open"}
    }

    struct!(Issue, Map.merge(defaults, attrs))
  end

  describe "board_visible?/2" do
    test "keeps open labeled issues" do
      assert Eligibility.board_visible?(issue(%{}), @config)
    end

    test "drops pull requests even when open and labeled" do
      pr =
        issue(%{
          labels: ["ai-task"],
          raw: %{"state" => "open", "pull_request" => %{}}
        })

      refute Eligibility.board_visible?(pr, @config)
    end

    test "drops closed PRs that would otherwise default to todo" do
      pr =
        issue(%{
          labels: [],
          raw: %{"state" => "closed", "pull_request" => %{"url" => "https://example"}}
        })

      refute Eligibility.board_visible?(pr, @config)
    end

    test "drops unlabeled open issues when required_labels is set" do
      refute Eligibility.board_visible?(issue(%{labels: []}), @config)
    end

    test "keeps closed issues with an explicit status label" do
      done =
        issue(%{
          status: "done",
          labels: ["ai-task", "status: done"],
          raw: %{"state" => "closed"}
        })

      assert Eligibility.board_visible?(done, @config)
    end

    test "drops closed issues without a status label" do
      closed_bug =
        issue(%{
          labels: ["ai-task"],
          raw: %{"state" => "closed"}
        })

      refute Eligibility.board_visible?(closed_bug, @config)
    end

    test "without required_labels, open issues still show" do
      config = Map.put(@config, :required_labels, [])
      assert Eligibility.board_visible?(issue(%{labels: []}), config)
    end
  end
end
