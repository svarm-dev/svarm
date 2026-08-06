defmodule Svarm.Tracker.GitHub.ChecksTest do
  use ExUnit.Case, async: true

  alias Svarm.Tracker.GitHub.Checks

  describe "classify/3" do
    test "in_progress when any run not completed" do
      runs = [
        %{"name" => "build", "status" => "completed", "conclusion" => "success"},
        %{"name" => "test", "status" => "in_progress", "conclusion" => nil}
      ]

      assert %{conclusion: :in_progress, check_count: 2} = Checks.classify(runs, "abc")
    end

    test "failed when completed failure" do
      runs = [
        %{"name" => "ci", "status" => "completed", "conclusion" => "failure"},
        %{"name" => "lint", "status" => "completed", "conclusion" => "success"}
      ]

      assert %{conclusion: :failed, failed_names: ["ci"]} = Checks.classify(runs, "sha1")
    end

    test "failed for timed_out and action_required" do
      runs = [
        %{"name" => "a", "status" => "completed", "conclusion" => "timed_out"},
        %{"name" => "b", "status" => "completed", "conclusion" => "action_required"}
      ]

      assert %{conclusion: :failed, failed_names: names} = Checks.classify(runs, "s")
      assert "a" in names
      assert "b" in names
    end

    test "passed when all success/neutral/skipped or empty" do
      assert %{conclusion: :passed, check_count: 0} = Checks.classify([], "s")

      runs = [
        %{"name" => "ok", "status" => "completed", "conclusion" => "success"},
        %{"name" => "skip", "status" => "completed", "conclusion" => "skipped"}
      ]

      assert %{conclusion: :passed} = Checks.classify(runs, "s")
    end

    test "does not fail while still running even if another job already failed" do
      runs = [
        %{"name" => "fast_fail", "status" => "completed", "conclusion" => "failure"},
        %{"name" => "slow", "status" => "in_progress", "conclusion" => nil}
      ]

      assert %{conclusion: :in_progress} = Checks.classify(runs, "s")
    end
  end

  describe "summarize_pr_checks/5 with stub Req" do
    defmodule StubReq do
      def get(url, opts) do
        cond do
          String.contains?(url, "/pulls/") ->
            case Process.get(:stub_pr) do
              :draft ->
                {:ok, %{status: 200, body: %{"head" => %{"sha" => "deadbeef"}, "draft" => true}}}

              :missing_sha ->
                {:ok, %{status: 200, body: %{"head" => %{}, "draft" => false}}}

              _ ->
                {:ok, %{status: 200, body: %{"head" => %{"sha" => "deadbeef"}, "draft" => false}}}
            end

          String.contains?(url, "/check-runs") ->
            runs = Process.get(:stub_runs, [])
            {:ok, %{status: 200, body: %{"check_runs" => runs, "total_count" => length(runs)}}}

          true ->
            flunk("unexpected URL #{url} opts=#{inspect(opts)}")
        end
      end
    end

    test "draft + skip_draft → pending" do
      Process.put(:stub_pr, :draft)

      assert {:ok, %{conclusion: :pending, draft: true}} =
               Checks.summarize_pr_checks("o", "r", 1, %{api_key: "t"},
                 req: StubReq,
                 skip_draft: true
               )
    end

    test "failed matrix from fixture runs" do
      Process.put(:stub_pr, :ok)

      Process.put(:stub_runs, [
        %{"name" => "mix", "status" => "completed", "conclusion" => "failure"}
      ])

      assert {:ok, %{conclusion: :failed, head_sha: "deadbeef", failed_names: ["mix"]}} =
               Checks.summarize_pr_checks("o", "r", 7, %{api_key: "t"}, req: StubReq)
    end

    test "passed when checks green" do
      Process.put(:stub_pr, :ok)

      Process.put(:stub_runs, [
        %{"name" => "mix", "status" => "completed", "conclusion" => "success"}
      ])

      assert {:ok, %{conclusion: :passed, head_sha: "deadbeef"}} =
               Checks.summarize_pr_checks("o", "r", 7, %{api_key: "t"}, req: StubReq)
    end
  end
end
