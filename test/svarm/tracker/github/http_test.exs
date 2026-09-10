defmodule Svarm.Tracker.GitHub.HTTPTest do
  use ExUnit.Case, async: true

  alias Svarm.Tracker.GitHub.HTTP

  defmodule StubReq do
    def get(_url, _opts), do: Process.get(:pr_response)
  end

  test "pr_merged is true only when merged is boolean true" do
    Process.put(:pr_response, {:ok, %{status: 200, body: %{"merged" => true}}})
    assert {:ok, true} = HTTP.pr_merged(StubReq, "o", "r", 1, [], [])
  end

  test "closed unmerged PR is not merged" do
    Process.put(
      :pr_response,
      {:ok, %{status: 200, body: %{"merged" => false, "state" => "closed"}}}
    )

    assert {:ok, false} = HTTP.pr_merged(StubReq, "o", "r", 1, [], [])
  end

  test "missing merged field is not a merge" do
    Process.put(:pr_response, {:ok, %{status: 200, body: %{"state" => "open"}}})
    assert {:ok, false} = HTTP.pr_merged(StubReq, "o", "r", 1, [], [])
  end

  test "HTTP error does not invent a merge" do
    Process.put(:pr_response, {:ok, %{status: 502, body: %{}}})
    assert {:error, {:http_error, 502}} = HTTP.pr_merged(StubReq, "o", "r", 1, [], [])
  end

  test "network error does not invent a merge" do
    Process.put(:pr_response, {:error, :timeout})
    assert {:error, :network_error} = HTTP.pr_merged(StubReq, "o", "r", 1, [], [])
  end

  describe "next_issues_url/3" do
    @next "https://api.github.com/repos/acme/widgets/issues?page=2"

    test "reads rel=next from a GitHub Link header" do
      headers = %{
        "link" => [
          ~s(<#{@next}>; rel="next", <https://api.github.com/repos/acme/widgets/issues?page=4>; rel="last")
        ]
      }

      assert HTTP.next_issues_url(headers, "acme", "widgets") == @next
    end

    test "accepts /repositories/{id}/issues next links" do
      url = "https://api.github.com/repositories/1300192/issues?page=2"
      headers = %{"Link" => [~s(<#{url}>; rel="next")]}
      assert HTTP.next_issues_url(headers, "acme", "widgets") == url
    end

    test "ignores off-origin next links" do
      headers = %{"link" => [~s(<https://evil.example/steal>; rel="next")]}
      assert HTTP.next_issues_url(headers, "acme", "widgets") == nil
    end

    test "ignores non-collection issue paths" do
      headers = %{
        "link" => [~s(<https://api.github.com/repos/acme/widgets/issues/12/comments>; rel="next")]
      }

      assert HTTP.next_issues_url(headers, "acme", "widgets") == nil
    end

    test "returns nil when Link has no next" do
      headers = %{
        "link" => [~s(<https://api.github.com/repos/acme/widgets/issues?page=1>; rel="prev")]
      }

      assert HTTP.next_issues_url(headers, "acme", "widgets") == nil
    end
  end
end
