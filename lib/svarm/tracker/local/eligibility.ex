defmodule Svarm.Tracker.Local.Eligibility do
  @moduledoc """
  Pure eligibility function for the local kanban tracker.
  No side effects, no API calls, no database lookups.
  """
  alias Svarm.Issue

  @doc """
  Returns true if the issue is eligible for dispatch.
  Pure function — takes an Issue struct and config, returns a boolean.
  """
  def eligible?(%Issue{} = issue, config) do
    issue.tracker == :local and
      issue.status in config.active_states and
      issue.assignee not in config.ignored_assignees
  end
end
