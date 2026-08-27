defmodule Svarm.Tracker.GitHub.GetIssueTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Svarm.Approval
  alias Svarm.Tracker.GitHub

  defmodule StubReq do
    def get(url, opts) do
      send(self(), {:http_get, url, Keyword.take(opts, [:params, :json])})

      cond do
        single_issue_url?(url) ->
          Process.get(:github_issue_response, {:ok, %{status: 404, body: %{}}})

        list_state(opts) == "open" ->
          Process.get(:github_eligible_response, {:ok, %{status: 200, body: []}})

        true ->
          Process.get(:github_list_response, {:ok, %{status: 200, body: []}})
      end
    end

    def patch(url, opts) do
      send(self(), {:http_patch, url, Keyword.take(opts, [:params, :json])})
      Process.get(:github_patch_response, {:ok, %{status: 200, body: %{}}})
    end

    defp single_issue_url?(url) do
      match?({_n, ""}, Integer.parse(Path.basename(url)))
    end

    defp list_state(opts) do
      opts |> Keyword.get(:params, %{}) |> Map.get(:state)
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

  describe "get_issue/2 by number and node_id" do
    test "todo (open, no status label)" do
      payload = gh_issue(%{"node_id" => "I_todo", "labels" => [], "state" => "open"})
      assert_resolves(payload, "todo")
    end

    test "pending_approval (open, not eligible)" do
      payload =
        gh_issue(%{
          "node_id" => "I_pending",
          "labels" => [%{"name" => "status: pending-approval"}],
          "state" => "open"
        })

      assert_resolves(payload, "pending_approval")
      refute_eligible(payload)
    end

    test "review (open, not eligible)" do
      payload =
        gh_issue(%{
          "node_id" => "I_review",
          "labels" => [%{"name" => "status: review"}],
          "state" => "open"
        })

      assert_resolves(payload, "review")
      refute_eligible(payload)
    end

    test "closed-done (closed + status: done, not eligible)" do
      payload =
        gh_issue(%{
          "node_id" => "I_done",
          "labels" => [%{"name" => "status: done"}],
          "state" => "closed"
        })

      assert_resolves(payload, "done")
      refute_eligible(payload)
    end
  end

  describe "node_id fallback is list_issues, not list_eligible" do
    test "closed-done is missing from the open list but found via state=all" do
      payload =
        gh_issue(%{
          "node_id" => "I_done",
          "labels" => [%{"name" => "status: done"}],
          "state" => "closed"
        })

      stub_issue(payload)
      stub_list([payload])
      stub_eligible([])

      assert {:ok, []} = GitHub.list_eligible(@config)
      flush_http()

      assert {:ok, issue} = GitHub.get_issue(@config, "I_done")
      assert issue.source_id == "42"
      assert issue.id == "I_done"
      assert issue.status == "done"

      assert_received {:http_get, url, opts}
      assert url =~ "/repos/acme/widgets/issues"
      refute url =~ ~r{/issues/\d+$}
      assert opts[:params][:state] == "all"
    end

    test "unknown node_id is not_found even when eligible issues exist" do
      eligible = gh_issue(%{"node_id" => "I_other", "number" => 7, "state" => "open"})
      stub_eligible([eligible])
      stub_list([eligible])

      assert {:error, :not_found} = GitHub.get_issue(@config, "I_missing")
    end

    test "list_issues rate_limit is not rewritten as not_found" do
      stub_list_response({:ok, %{status: 429, headers: %{"retry-after" => ["15"]}}})
      stub_eligible([])

      assert {:error, reason} = GitHub.get_issue(@config, "I_pending")
      assert reason.type == :rate_limit
      assert reason.retry_after == 15
    end

    test "list_issues network error is not rewritten as not_found" do
      stub_list_response({:error, :timeout})
      stub_eligible([])

      assert {:error, reason} = GitHub.get_issue(@config, "I_pending")
      assert reason.type == :network_error
    end
  end

  describe "update_status/3 via find_issue" do
    test "PATCHes numeric source_id when keyed by node_id for pending_approval" do
      payload =
        gh_issue(%{
          "node_id" => "I_pending",
          "labels" => [%{"name" => "status: pending-approval"}, %{"name" => "ai-task"}],
          "state" => "open"
        })

      stub_list([payload])
      stub_eligible([])

      assert {:ok, []} = GitHub.list_eligible(@config)
      assert :ok = GitHub.update_status(@config, "I_pending", "todo")

      assert_received {:http_patch, url, opts}
      assert url =~ "/repos/acme/widgets/issues/42"
      refute "status: pending-approval" in opts[:json][:labels]
      assert "ai-task" in opts[:json][:labels]
    end
  end

  describe "get_issues/2 list snapshot" do
    test "multiple ids in the list snapshot issue no per-id GET" do
      a = gh_issue(%{"number" => 11, "node_id" => "I_11", "state" => "open"})
      b = gh_issue(%{"number" => 12, "node_id" => "I_12", "state" => "open"})
      stub_list([a, b])
      stub_eligible([])
      stub_issue_missing()
      flush_http()

      assert {:ok, results} = GitHub.get_issues(@config, ["11", "I_12", "11"])
      assert {:ok, %{source_id: "11", id: "I_11"}} = results["11"]
      assert {:ok, %{source_id: "12", id: "I_12"}} = results["I_12"]
      assert map_size(results) == 2

      gets = drain_http_gets([])

      list_gets =
        Enum.filter(gets, fn {url, opts} -> list_url?(url) and list_state(opts) == "all" end)

      assert match?([_], list_gets)
      refute Enum.any?(gets, fn {url, _} -> single_issue_url?(url) end)
    end

    test "numeric id missing from the snapshot still GETs /issues/{n}" do
      listed = gh_issue(%{"number" => 11, "node_id" => "I_11", "state" => "open"})
      missing = gh_issue(%{"number" => 99, "node_id" => "I_99", "state" => "open"})
      stub_list([listed])
      stub_issue(missing)
      flush_http()

      assert {:ok, results} = GitHub.get_issues(@config, ["11", "99"])
      assert {:ok, %{id: "I_11"}} = results["11"]
      assert {:ok, %{id: "I_99", source_id: "99"}} = results["99"]

      gets = drain_http_gets([])
      assert Enum.any?(gets, fn {url, _} -> url =~ ~r{/issues/99$} end)
      refute Enum.any?(gets, fn {url, _} -> url =~ ~r{/issues/11$} end)
    end

    test "node_id missing from a successful list is not_found without a per-id GET" do
      listed = gh_issue(%{"number" => 11, "node_id" => "I_11", "state" => "open"})
      stub_list([listed])
      stub_issue_missing()
      flush_http()

      assert {:ok, results} = GitHub.get_issues(@config, ["I_11", "I_missing"])
      assert {:ok, %{id: "I_11"}} = results["I_11"]
      assert {:error, :not_found} = results["I_missing"]

      gets = drain_http_gets([])
      refute Enum.any?(gets, fn {url, _} -> single_issue_url?(url) end)
    end

    test "failed list is a whole-batch error (no per-id GET fan-out)" do
      stub_list_response({:ok, %{status: 429, headers: %{"retry-after" => ["15"]}}})
      stub_issue_missing()
      flush_http()

      assert {:error, reason} = GitHub.get_issues(@config, ["42", "I_pending"])
      assert reason.type == :rate_limit

      gets = drain_http_gets([])
      refute Enum.any?(gets, fn {url, _} -> single_issue_url?(url) end)
    end

    test "a single id stays one-shot get_issue (no list)" do
      payload = gh_issue(%{"number" => 42, "node_id" => "I_42", "state" => "open"})
      stub_issue(payload)
      stub_list([])
      flush_http()

      assert {:ok, %{"42" => {:ok, %{id: "I_42"}}}} = GitHub.get_issues(@config, ["42"])

      gets = drain_http_gets([])
      assert Enum.any?(gets, fn {url, _} -> url =~ ~r{/issues/42$} end)
      refute Enum.any?(gets, fn {url, opts} -> list_url?(url) and list_state(opts) == "all" end)
    end
  end

  describe "Approval.approve/1 with GitHub node_id" do
    setup do
      Approval.__override_tracker__(GitHub, @config)
      :ok
    end

    test "approves pending_approval node_id that is not in list_eligible" do
      payload =
        gh_issue(%{
          "node_id" => "I_pending",
          "labels" => [%{"name" => "status: pending-approval"}, %{"name" => "ai-task"}],
          "state" => "open"
        })

      stub_list([payload])
      stub_eligible([])

      assert {:ok, []} = GitHub.list_eligible(@config)
      assert {:ok, issue} = GitHub.get_issue(@config, "I_pending")
      assert issue.status == "pending_approval"

      assert :ok = Approval.approve("I_pending")
      assert_received {:http_patch, url, opts}
      assert url =~ "/issues/42"
      refute "status: pending-approval" in opts[:json][:labels]
      assert "ai-task" in opts[:json][:labels]
    end
  end

  defp assert_resolves(payload, status) do
    node_id = payload["node_id"]
    number = to_string(payload["number"])

    stub_issue(payload)
    stub_list([payload])
    stub_eligible([])

    assert {:ok, by_number} = GitHub.get_issue(@config, number)
    assert by_number.status == status
    assert by_number.source_id == number
    assert by_number.id == node_id

    assert {:ok, by_node} = GitHub.get_issue(@config, node_id)
    assert by_node.status == status
    assert by_node.source_id == number
    assert by_node.id == node_id
  end

  defp refute_eligible(payload) do
    stub_list([payload])
    stub_eligible([])
    assert {:ok, []} = GitHub.list_eligible(@config)
    assert {:ok, issue} = GitHub.get_issue(@config, payload["node_id"])
    assert issue.id == payload["node_id"]
  end

  defp stub_issue(body) do
    Process.put(:github_issue_response, {:ok, %{status: 200, body: body}})
  end

  defp stub_issue_missing do
    Process.put(:github_issue_response, {:ok, %{status: 404, body: %{}}})
  end

  defp single_issue_url?(url) do
    match?({_n, ""}, Integer.parse(Path.basename(url)))
  end

  defp list_url?(url), do: url =~ ~r{/issues$} or url =~ ~r{/issues\?}

  defp list_state(opts), do: opts |> Keyword.get(:params, %{}) |> Map.get(:state)

  defp drain_http_gets(acc) do
    receive do
      {:http_get, url, opts} -> drain_http_gets([{url, opts} | acc])
      {:http_patch, _, _} -> drain_http_gets(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp stub_list(issues) do
    stub_list_response({:ok, %{status: 200, body: issues}})
  end

  defp stub_list_response(response) do
    Process.put(:github_list_response, response)
  end

  defp stub_eligible(issues) do
    Process.put(:github_eligible_response, {:ok, %{status: 200, body: issues}})
  end

  defp flush_http do
    receive do
      {:http_get, _, _} -> flush_http()
      {:http_patch, _, _} -> flush_http()
    after
      0 -> :ok
    end
  end

  defp gh_issue(overrides) do
    Map.merge(
      %{
        "number" => 42,
        "node_id" => "I_42",
        "title" => "Lookup me",
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
