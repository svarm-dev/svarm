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
end
