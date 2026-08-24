defmodule Svarm.Tracker.GitHub.Normalize do
  @moduledoc """
  Converts GitHub REST API issue responses to `%Svarm.Issue{}` structs.

  GitHub issues have no native retry counter. `from_api_response/2` sets
  `attempts: 0`. `attach_attempts/1` overlays `task_coordination.attempts`
  (SQLite, not Orchestrator `retry_attempts`) onto the issue.
  """
  alias Svarm.{Coordination, Issue}

  @doc """
  Convert a GitHub API issue response to an Issue struct.
  Status is derived from labels per the tracker config.
  """
  def from_api_response(gh_issue, config) do
    labels = Map.get(gh_issue, "labels", []) |> Enum.map(& &1["name"])

    %Issue{
      id: build_id(gh_issue),
      source_id: to_string(gh_issue["number"]),
      title: gh_issue["title"],
      body: gh_issue["body"] || "",
      type: infer_type(labels),
      assignee: extract_assignee(gh_issue),
      status: map_status(labels, config),
      priority: 0,
      attempts: 0,
      created_by: gh_issue["user"]["login"] || "github",
      created_at: parse_created_at(gh_issue["created_at"]),
      tenant: gh_issue["repository_url"] |> String.split("/") |> Enum.at(-2) || "",
      labels: labels,
      depends_on: [],
      tracker: :github,
      raw: gh_issue
    }
  end

  @doc """
  Overlay stored retry attempts from coordination onto normalized issues.

  Missing rows stay `0`. Lists use one `get_many/1` (not N+1).
  """
  @spec attach_attempts(Issue.t()) :: Issue.t()
  @spec attach_attempts([Issue.t()]) :: [Issue.t()]
  def attach_attempts(%Issue{} = issue) do
    hd(attach_attempts([issue]))
  end

  def attach_attempts(issues) when is_list(issues) do
    by_id = Coordination.get_many(Enum.map(issues, & &1.id))

    Enum.map(issues, fn issue ->
      case Map.get(by_id, issue.id) do
        %{attempts: n} when is_integer(n) and n >= 0 -> %{issue | attempts: n}
        _ -> issue
      end
    end)
  end

  defp build_id(gh_issue) do
    # Use node_id for stability (survives issue number changes on transfer)
    Map.get(gh_issue, "node_id", "gh_#{gh_issue["number"]}")
  end

  defp extract_assignee(gh_issue) do
    case Map.get(gh_issue, "assignee") do
      %{"login" => login} -> login
      nil -> nil
      _ -> nil
    end
  end

  defp map_status(labels, config) do
    label_map = Map.get(config, :status_labels, %{})
    active_states = Map.get(config, :active_states, [])

    Enum.find_value(labels, &Map.get(label_map, &1)) || hd(active_states)
  end

  defp infer_type(labels) do
    cond do
      "research" in labels -> "research"
      "docs" in labels -> "docs"
      true -> "code"
    end
  end

  defp parse_created_at(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp parse_created_at(_), do: 0
end
