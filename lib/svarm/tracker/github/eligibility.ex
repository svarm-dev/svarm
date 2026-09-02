defmodule Svarm.Tracker.GitHub.Eligibility do
  @moduledoc """
  Pure eligibility / board-visibility predicates for GitHub issues.
  No side effects, no API calls, no database lookups.

  Dispatch (`eligible?/2`) skips issues assigned to anyone not listed in
  `config.agent_assignees` (GitHub logins, case-insensitive). Unassigned
  issues stay eligible. That allowlist is WORKFLOW `tracker.agent_assignees`
  — not `agents.toml` names and not `approval.trusted_assignees` (those are
  board/agent keys, not GitHub logins). `board_visible?/2` does not apply
  the filter, so human-owned labeled issues still appear on the board.
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
      dispatchable_assignee?(issue, config)
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

  # Unassigned, or assigned to a login in tracker.agent_assignees.
  # GitHub logins are case-insensitive. Empty allowlist → only unassigned.
  defp dispatchable_assignee?(%Issue{assignee: assignee}, _config)
       when assignee in [nil, ""],
       do: true

  defp dispatchable_assignee?(%Issue{assignee: assignee}, config) do
    needle = String.downcase(assignee)

    config
    |> Map.get(:agent_assignees, [])
    |> Enum.any?(&(String.downcase(&1) == needle))
  end
end
