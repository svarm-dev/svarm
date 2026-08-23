defmodule Svarm.Tracker.GitHub.AttemptsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Svarm.{Coordination, Repo}
  alias Svarm.Tracker.GitHub
  alias Svarm.Tracker.GitHub.Normalize

  defmodule StubReq do
    def get(url, opts) do
      cond do
        String.ends_with?(url, "/comments") ->
          {:ok, %{status: 200, body: []}}

        single_issue_url?(url) ->
          Process.get(:github_issue_response, {:ok, %{status: 404, body: %{}}})

        true ->
          state = opts |> Keyword.get(:params, %{}) |> Map.get(:state)

          if state == "open" do
            Process.get(:github_eligible_response, {:ok, %{status: 200, body: []}})
          else
            Process.get(:github_list_response, {:ok, %{status: 200, body: []}})
          end
      end
    end

    def patch(_url, _opts), do: {:ok, %{status: 200, body: %{}}}
    def post(_url, _opts), do: {:ok, %{status: 201, body: %{}}}

    defp single_issue_url?(url) do
      match?({_n, ""}, Integer.parse(Path.basename(url)))
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
    Repo.delete_all(Coordination)
    :ok
  end

  test "update_attempts persists and get_issue reads it back (not hardcoded 0)" do
    payload = gh_issue(%{"node_id" => "I_attempts", "number" => 42})
    stub_issue(payload)
    stub_list([payload])

    assert {:ok, before} = GitHub.get_issue(@config, "I_attempts")
    assert before.attempts == 0

    raw = Normalize.from_api_response(payload, %{status_labels: %{}, active_states: ["todo"]})
    assert raw.attempts == 0

    assert :ok = GitHub.update_attempts(@config, "I_attempts", 2)
    assert Coordination.get("I_attempts").attempts == 2

    assert {:ok, by_node} = GitHub.get_issue(@config, "I_attempts")
    assert by_node.attempts == 2

    assert {:ok, by_number} = GitHub.get_issue(@config, "42")
    assert by_number.attempts == 2
    assert by_number.id == "I_attempts"
  end

  test "list_issues overlays stored attempts without leaving cards at 0" do
    payload = gh_issue(%{"node_id" => "I_list", "number" => 7})
    stub_list([payload])

    assert :ok = GitHub.update_attempts(@config, "I_list", 3)
    assert {:ok, [issue]} = GitHub.list_issues(@config)
    assert issue.id == "I_list"
    assert issue.attempts == 3
  end

  test "attach_attempts is a no-op when no coordination row exists" do
    payload = gh_issue(%{"node_id" => "I_fresh"})
    issue = Normalize.from_api_response(payload, %{status_labels: %{}, active_states: ["todo"]})
    assert Normalize.attach_attempts(issue).attempts == 0
    assert Normalize.attach_attempts([]) == []
  end

  defp stub_issue(body) do
    Process.put(:github_issue_response, {:ok, %{status: 200, body: body}})
  end

  defp stub_list(issues) do
    Process.put(:github_list_response, {:ok, %{status: 200, body: issues}})
  end

  defp gh_issue(overrides) do
    Map.merge(
      %{
        "number" => 42,
        "node_id" => "I_42",
        "title" => "Persist me",
        "body" => "",
        "labels" => [],
        "assignee" => %{"login" => "demo"},
        "user" => %{"login" => "alice"},
        "created_at" => "2026-01-01T00:00:00Z",
        "repository_url" => "https://api.github.com/repos/acme/widgets",
        "state" => "open"
      },
      overrides
    )
  end
end
