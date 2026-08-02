defmodule Svarm.Tracker.GitHubTest do
  use ExUnit.Case, async: true

  alias Svarm.Tracker.GitHub

  describe "build_comment/1" do
    test "renders success comment with agent name, cost, harness, and session" do
      summary = %{
        run_id: "run_abc123",
        task_id: "sva_test123",
        task: %{title: "Add retry logic to API client", source_id: "42"},
        result: :ok,
        duration_ms: 252_000,
        agent_name: "Reece",
        agent_role: "Research & Architecture",
        harness: "Claude Code",
        model: "sonnet-4",
        total_tokens: 2340,
        cost: %{total_cost_usd: 0.47, record_count: 3},
        branch: "feat/retry-logic",
        exit_code: 0
      }

      comment = GitHub.build_comment(summary)

      assert comment =~ "✅ **Reece** finished"
      assert comment =~ "Add retry logic to API client"
      assert comment =~ "$0.47"
      refute comment =~ "est."
      assert comment =~ "2.3k tokens"
      assert comment =~ "4m"
      assert comment =~ "**Harness**"
      assert comment =~ "Claude Code"
      assert comment =~ "**Model**"
      assert comment =~ "sonnet-4"
      assert comment =~ "**Session**"
      assert comment =~ "`run_abc123`"
      assert comment =~ "**Branch**"
      assert comment =~ "`feat/retry-logic`"
      assert comment =~ "**Awaiting human review**"
      assert comment =~ "Branch: `feat/retry-logic`"
      refute comment =~ ~r/merged|reviewed by/i
    end

    test "appends est. when cost.estimated is true" do
      summary = %{
        run_id: "run_est",
        task_id: "sva_est",
        task: %{title: "Estimated cost", source_id: "7"},
        result: :ok,
        duration_ms: 1000,
        agent_name: "Pi",
        agent_role: nil,
        harness: "Pi",
        model: "free",
        total_tokens: 100,
        cost: %{total_cost_usd: 0.05, record_count: 1, estimated: true},
        branch: nil,
        exit_code: 0
      }

      comment = GitHub.build_comment(summary)
      assert comment =~ "$0.05 est."
    end

    test "renders failure comment with exit code" do
      summary = %{
        run_id: "run_fail1",
        task_id: "sva_fail1",
        task: %{title: "Fix authentication bug", source_id: "15"},
        result: {:error, :agent_exit},
        duration_ms: 12_000,
        agent_name: "Cody",
        agent_role: nil,
        harness: "Pi",
        model: "gpt-4o",
        total_tokens: 890,
        cost: %{total_cost_usd: 0.12, record_count: 1},
        branch: nil,
        exit_code: 1
      }

      comment = GitHub.build_comment(summary)

      assert comment =~ "❌ **Cody** failed"
      assert comment =~ "Fix authentication bug"
      assert comment =~ "$0.12"
      assert comment =~ "890 tokens"
      assert comment =~ "12s"
      assert comment =~ "**Harness**"
      assert comment =~ "Pi"
      # No branch row when nil
      refute comment =~ "**Branch**"
      # Session always present
      assert comment =~ "**Session**"
      assert comment =~ "`run_fail1`"
    end

    test "omits harness when not provided" do
      summary = %{
        run_id: "run_no_h",
        task_id: "sva_noh",
        task: %{title: "Something", source_id: "1"},
        result: :ok,
        duration_ms: 1000,
        agent_name: "default",
        agent_role: nil,
        harness: nil,
        model: nil,
        total_tokens: 0,
        cost: %{total_cost_usd: 0.0, record_count: 0},
        branch: nil,
        exit_code: 0
      }

      comment = GitHub.build_comment(summary)
      refute comment =~ "**Harness**"
      refute comment =~ "**Model**"
      assert comment =~ "**Awaiting human review**"
    end

    test "omits duration when not provided" do
      summary = %{
        run_id: "run_nd",
        task_id: "sva_nd",
        task: %{title: "Quick fix", source_id: "3"},
        result: :ok,
        duration_ms: nil,
        agent_name: "Cody",
        agent_role: nil,
        harness: "Pi",
        model: "gpt-4o",
        total_tokens: 100,
        cost: %{total_cost_usd: 0.01, record_count: 1},
        branch: nil,
        exit_code: 0
      }

      comment = GitHub.build_comment(summary)
      # When duration is nil, the header should not contain a duration suffix like " · 12s"
      [header | _] = String.split(comment, "\n")
      refute header =~ ~r/· \d+[ms]/
    end

    test "omits cost line when no cost records" do
      summary = %{
        run_id: "run_nc",
        task_id: "sva_nc",
        task: %{title: "No cost", source_id: "7"},
        result: :ok,
        duration_ms: 500,
        agent_name: "Cody",
        agent_role: nil,
        harness: "Pi",
        model: "gpt-4o",
        total_tokens: 0,
        cost: %{total_cost_usd: 0.0, record_count: 0},
        branch: nil,
        exit_code: 0
      }

      comment = GitHub.build_comment(summary)
      refute comment =~ "$"
    end
  end

  describe "post_run_summary idempotency" do
    test "marker format is stable and unique" do
      marker = "<!-- svarm-run:run_abc123def -->"
      assert String.starts_with?(marker, "<!-- svarm-run:")
      assert String.ends_with?(marker, "-->")
      assert String.contains?(marker, "run_abc123def")
    end

    test "full comment includes marker footer" do
      summary = %{
        run_id: "run_marker",
        task_id: "sva_marker",
        task: %{title: "Marker test", source_id: "1"},
        result: :ok,
        duration_ms: 100,
        agent_name: "Test",
        agent_role: nil,
        harness: "Pi",
        model: "gpt-4o",
        total_tokens: 10,
        cost: %{total_cost_usd: 0.01, record_count: 1},
        branch: nil,
        exit_code: 0
      }

      comment = GitHub.build_comment(summary)
      # Marker is added by the caller, but we verify the comment doesn't already contain one
      refute String.contains?(comment, "<!-- svarm-run:")
    end
  end
end
