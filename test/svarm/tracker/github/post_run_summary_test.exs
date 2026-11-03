defmodule Svarm.Tracker.GitHub.PostRunSummaryTest do
  use ExUnit.Case, async: false

  alias Svarm.Tracker.GitHub

  # Req stand-in: `config[:req]` is the adapter's injection seam. Both calls run
  # in the test process, so the process dictionary is the stub's state. Posted
  # bodies are recorded and served back on `get/2`, so a repeat summary meets
  # its own earlier comment the way the real API would.
  defmodule StubReq do
    def get(url, opts) do
      send(self(), {:get, url, opts})
      Process.get(:comment_pages) || {:ok, %{status: 200, body: posted_comments()}}
    end

    def post(url, opts) do
      send(self(), {:post, url, opts})
      body = opts[:json][:body]
      Process.put(:posted_bodies, [body | Process.get(:posted_bodies, [])])
      Process.get(:post_response, {:ok, %{status: 201, body: %{}}})
    end

    defp posted_comments do
      :posted_bodies
      |> Process.get([])
      |> Enum.reverse()
      |> Enum.map(&%{"body" => &1})
    end
  end

  @config %{
    owner: "acme",
    repo: "widgets",
    api_key: "t",
    req: StubReq,
    kind: :github,
    active_states: ["todo", "in_progress"],
    terminal_states: ["done", "failed", "review"]
  }

  setup do
    Process.delete(:comment_pages)
    Process.delete(:post_response)
    Process.delete(:posted_bodies)
    :ok
  end

  test "posts the board's stop reason on the issue" do
    assert :ok = GitHub.post_run_summary(@config, "sva_stop1", summary(%{}))

    assert_received {:post, url, opts}
    assert url =~ "/issues/42/comments"
    body = opts[:json][:body]
    assert body =~ "**Stopped:** Needs review."
    assert Svarm.Board.wait_reason_label(:review) == "Needs review"
    assert body =~ "<!-- svarm-run:run_stop1 -->"
    refute_received {:post, _, _}
  end

  test "a failed run names the failed reason" do
    assert :ok =
             GitHub.post_run_summary(
               @config,
               "sva_fail",
               summary(%{
                 run_id: "run_fail",
                 result: {:error, :agent_exit},
                 stop_reason: :failed,
                 exit_code: 1
               })
             )

    assert_received {:post, _url, opts}
    assert opts[:json][:body] =~ "**Stopped:** Failed."
  end

  test "a run with no stop reason posts no stop line" do
    assert :ok = GitHub.post_run_summary(@config, "sva_plain", summary(%{stop_reason: nil}))

    assert_received {:post, _url, opts}
    body = opts[:json][:body]
    refute body =~ "**Stopped:**"
    assert body =~ "**Session**"
  end

  test "a stopped run posts exactly one comment across repeated summaries" do
    assert :ok = GitHub.post_run_summary(@config, "sva_stop1", summary(%{}))

    assert_received {:get, _url, _opts}
    assert_received {:post, _url, opts}
    assert opts[:json][:body] =~ "<!-- svarm-run:run_stop1 -->"

    assert :ok = GitHub.post_run_summary(@config, "sva_stop1", summary(%{}))

    assert_received {:get, _url, _opts}
    refute_received {:post, _, _}
  end

  test "each run gets its own comment" do
    Process.put(
      :comment_pages,
      {:ok, %{status: 200, body: [%{"body" => "<!-- svarm-run:run_stop1 -->"}]}}
    )

    assert :ok = GitHub.post_run_summary(@config, "sva_stop2", summary(%{run_id: "run_stop2"}))

    assert_received {:post, _url, opts}
    assert opts[:json][:body] =~ "<!-- svarm-run:run_stop2 -->"
  end

  test "the comment goes through the redaction path" do
    leaked = "ghp_" <> String.duplicate("a", 24)
    leaked_pr = "ghp_" <> String.duplicate("b", 24)

    assert :ok =
             GitHub.post_run_summary(
               @config,
               "sva_leak",
               summary(%{run_id: "run_leak", task_title: leaked, pr_url: leaked_pr})
             )

    assert_received {:post, _url, opts}
    body = opts[:json][:body]
    refute body =~ leaked
    refute body =~ leaked_pr
    assert body =~ "[redacted]"
    assert String.ends_with?(body, "<!-- svarm-run:run_leak -->")
  end

  test "a rejected comment is logged and does not fail the run" do
    Process.put(:post_response, {:ok, %{status: 403, body: %{}, headers: %{}}})

    assert :ok = GitHub.post_run_summary(@config, "sva_forbidden", summary(%{}))

    assert_received {:post, _url, _opts}
    refute_received {:post, _, _}
  end

  test "an API error is not retried" do
    Process.put(:post_response, {:error, :timeout})

    assert :ok = GitHub.post_run_summary(@config, "sva_timeout", summary(%{}))

    assert_received {:post, _url, _opts}
    refute_received {:post, _, _}
  end

  defp summary(overrides) do
    task_title = Map.get(overrides, :task_title, "Parser stops at EOF")

    base = %{
      run_id: "run_stop1",
      task_id: "sva_stop1",
      task: %{title: task_title, source_id: "42"},
      result: :ok,
      stop_reason: :review,
      duration_ms: 2_000,
      agent_name: "Cody",
      agent_role: nil,
      harness: "Pi",
      model: "gpt-4o",
      total_tokens: 10,
      cost: %{total_cost_usd: 0.02, record_count: 1},
      branch: nil,
      pr_url: nil,
      exit_code: 0
    }

    overrides
    |> Map.drop([:task_title])
    |> then(&Map.merge(base, &1))
  end
end
