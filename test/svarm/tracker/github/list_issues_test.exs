defmodule Svarm.Tracker.GitHub.ListIssuesTest do
  use ExUnit.Case, async: false

  alias Svarm.Tracker.GitHub

  defmodule StubReq do
    def get(_url, _opts), do: Process.get(:github_list_response)
  end

  defmodule PagedStub do
    def get(url, opts) do
      page = page_num(url, opts)
      send(self(), {:github_list_page, page, url})
      Process.get({:github_page, page}) || {:ok, %{status: 200, body: []}}
    end

    defp page_num(url, opts) do
      from_query =
        case URI.parse(url).query do
          q when is_binary(q) -> URI.decode_query(q)["page"]
          _ -> nil
        end

      from_params =
        case Keyword.get(opts, :params, %{}) do
          %{page: n} -> n
          %{"page" => n} -> n
          _ -> nil
        end

      case Integer.parse(to_string(from_query || from_params || 1)) do
        {n, ""} -> n
        _ -> 1
      end
    end
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

  describe "list pagination" do
    @paged_config %{
      owner: "acme",
      repo: "widgets",
      api_key: "t",
      req: PagedStub,
      active_states: ["todo", "in_progress"]
    }

    test "two pages via Link rel=next are both eligible" do
      stub_page(1, [gh_issue(1, "First")], next_link(2))
      stub_page(2, [gh_issue(2, "Second")], %{})

      assert {:ok, issues} = GitHub.list_eligible(@paged_config)
      assert Enum.map(issues, & &1.source_id) == ["1", "2"]
      assert_received {:github_list_page, 1, _}
      assert_received {:github_list_page, 2, _}
    end

    test "two pages via Link rel=next are both listed" do
      stub_page(1, [gh_issue(1, "First")], next_link(2))
      stub_page(2, [gh_issue(2, "Second")], %{})

      assert {:ok, issues} = GitHub.list_issues(@paged_config)
      assert Enum.map(issues, & &1.source_id) == ["1", "2"]
    end

    test "page-1 eligibility rules are unchanged when page 2 is present" do
      stub_page(1, [gh_issue(1, "Human", %{"assignee" => %{"login" => "alice"}})], next_link(2))
      stub_page(2, [gh_issue(2, "Open")], %{})

      assert {:ok, issues} = GitHub.list_eligible(@paged_config)
      assert Enum.map(issues, & &1.source_id) == ["2"]
    end

    test "stops at max_list_pages even when Link keeps offering next" do
      max = GitHub.HTTP.max_list_pages()

      for page <- 1..(max + 2) do
        stub_page(page, [gh_issue(page, "p#{page}")], next_link(page + 1))
      end

      assert {:ok, issues} = GitHub.list_issues(@paged_config)
      assert length(issues) == max
      assert Enum.map(issues, & &1.source_id) == Enum.map(1..max, &to_string/1)

      pages =
        for _ <- 1..max do
          assert_received {:github_list_page, page, _}
          page
        end

      assert pages == Enum.to_list(1..max)
      refute_received {:github_list_page, _, _}
    end

    test "a later-page HTTP error fails the list (not a partial page-1 board)" do
      stub_page(1, [gh_issue(1, "First")], next_link(2))
      Process.put({:github_page, 2}, {:ok, %{status: 403, headers: %{}}})

      assert {:error, reason} = GitHub.list_issues(@paged_config)
      assert reason.type == :rate_limit
    end
  end

  defp stub_page(page, issues, headers) do
    Process.put({:github_page, page}, {:ok, %{status: 200, body: issues, headers: headers}})
  end

  defp next_link(page) do
    url = "https://api.github.com/repos/acme/widgets/issues?page=#{page}"
    %{"link" => [~s(<#{url}>; rel="next")]}
  end

  defp gh_issue(number, title, overrides \\ %{}) do
    Map.merge(
      %{
        "number" => number,
        "node_id" => "I_#{number}",
        "title" => title,
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
