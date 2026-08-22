defmodule Svarm.Tracker.GitHub.ListIssuesTest do
  use ExUnit.Case, async: false

  alias Svarm.Tracker.GitHub

  defmodule StubReq do
    def get(_url, _opts), do: Process.get(:github_list_response)
  end

  @config %{owner: "acme", repo: "widgets", api_key: "t", req: StubReq}

  describe "list_issues/2 HTTP errors match list_eligible/1" do
    test "401 is auth_failure" do
      stub_list({:ok, %{status: 401}})
      assert_same_error(:auth_failure, "bad GitHub token")
    end

    test "403 is rate_limit with retry_after from header" do
      stub_list({:ok, %{status: 403, headers: %{"retry-after" => ["30"]}}})
      assert_same_error(:rate_limit, "rate limited", 30)
    end

    test "403 without retry-after defaults retry_after to 60" do
      stub_list({:ok, %{status: 403, headers: %{}}})
      assert_same_error(:rate_limit, "rate limited", 60)
    end

    test "404 is not_found" do
      stub_list({:ok, %{status: 404}})
      assert_same_error(:not_found, "repo acme/widgets not found")
    end

    test "5xx is server_error" do
      stub_list({:ok, %{status: 502, body: %{}}})
      assert_same_error(:server_error, "GitHub API error 502")
    end

    test "network error is network_error" do
      stub_list({:error, %{reason: :timeout}})
      assert_same_error(:network_error, "cannot reach GitHub API")
    end

    test "HTTP 200 with an empty issue list is {:ok, []}" do
      stub_list({:ok, %{status: 200, body: []}})
      assert {:ok, []} = GitHub.list_issues(@config)
      assert {:ok, []} = GitHub.list_eligible(@config)
    end

    test "429 is rate_limit with retry_after from header" do
      stub_list({:ok, %{status: 429, headers: %{"retry-after" => ["15"]}}})
      assert_same_error(:rate_limit, "rate limited", 15)
    end

    test "400 is tagged server_error, not an empty list" do
      stub_list({:ok, %{status: 400, body: %{"message" => "bad request"}}})
      assert_same_error(:server_error, "GitHub API error 400")
    end

    test "422 is tagged server_error, not an empty list" do
      stub_list({:ok, %{status: 422}})
      assert_same_error(:server_error, "GitHub API error 422")
    end

    test "unexpected error shape is tagged network_error, not CaseClauseError" do
      stub_list({:error, :timeout})
      assert_same_error(:network_error, "cannot reach GitHub API")
    end
  end

  defp stub_list(response), do: Process.put(:github_list_response, response)

  defp assert_same_error(type, message, retry_after \\ nil) do
    listed = GitHub.list_issues(@config)
    eligible = GitHub.list_eligible(@config)

    assert {:error, reason} = listed
    assert reason == elem(eligible, 1)
    assert reason.type == type
    assert reason.message == message
    assert reason.retry_after == retry_after
    assert Map.keys(reason) -- [:type, :message, :retry_after] == []
  end
end
