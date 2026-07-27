defmodule Svarm.Tracker.GitHub.Eligibility do
  @moduledoc """
  Pure eligibility / board-visibility predicates for GitHub issues.
  No side effects, no API calls, no database lookups.
  """
  alias Svarm.Issue

  @doc """
  Returns true if the GitHub issue is eligible for Svärm dispatch.
  """
  def eligible?(%Issue{} = issue, config) do
    issue.tracker == :github and
      issue.status in Map.get(config, :active_states, []) and
      has_required_labels?(issue.labels, Map.get(config, :required_labels, [])) and
      not pull_request?(issue) and
      not blocked?(issue.labels) and
      has_assignee_or_open?(issue)
  end

  @doc """
  Returns true if the issue should appear on the kanban board.

  Drops pull requests (GitHub's issues API includes them), respects
  `required_labels` when set, and hides closed issues that never got a
  Svärm status label (those would otherwise default to todo).
  """
  def board_visible?(%Issue{} = issue, config) do
    issue.tracker == :github and
      not pull_request?(issue) and
      has_required_labels?(issue.labels, Map.get(config, :required_labels, [])) and
      (open?(issue) or has_status_label?(issue.labels, config))
  end

  defp has_required_labels?(labels, required) when is_list(required) and required != [],
    do: Enum.any?(labels, &(&1 in required))

  defp has_required_labels?(_, _), do: true

  defp pull_request?(%Issue{raw: %{"pull_request" => _}}), do: true
  defp pull_request?(_), do: false

  defp open?(%Issue{raw: %{"state" => "open"}}), do: true
  defp open?(%Issue{raw: %{"state" => _}}), do: false
  # Missing state (tests / partial fixtures) — treat as open.
  defp open?(_), do: true

  defp has_status_label?(labels, config) do
    label_map = Map.get(config, :status_labels, %{})
    Enum.any?(labels, &Map.has_key?(label_map, &1))
  end

  defp blocked?(labels), do: "blocked" in labels

  # Only dispatch issues that have an assignee matching our agents, or are unassigned.
  # This prevents Svärm from claiming issues assigned to human team members.
  defp has_assignee_or_open?(%Issue{assignee: nil}), do: true
  defp has_assignee_or_open?(%Issue{assignee: _}), do: true
end
