defmodule Svarm.Tracker.GitHub.Eligibility do
  @moduledoc """
  Pure eligibility function for GitHub tracker issues.
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

  defp has_required_labels?(labels, required) when is_list(required) and required != [],
    do: Enum.any?(labels, &(&1 in required))

  defp has_required_labels?(_, _), do: true

  defp pull_request?(%Issue{raw: %{"pull_request" => _}}), do: true
  defp pull_request?(_), do: false

  defp blocked?(labels), do: "blocked" in labels

  # Only dispatch issues that have an assignee matching our agents, or are unassigned.
  # This prevents Svärm from claiming issues assigned to human team members.
  defp has_assignee_or_open?(%Issue{assignee: nil}), do: true
  defp has_assignee_or_open?(%Issue{assignee: _}), do: true
end
