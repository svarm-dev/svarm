defmodule Svarm.Tracker.Kaneo.Eligibility do
  @moduledoc """
  Pure dispatch eligibility for Kaneo tasks. No side effects, no API calls.

  A task is eligible when it is a Kaneo task and sits in one of the
  configured active columns (`tracker.active_states`, matched against the
  Kaneo column slug).
  """
  alias Svarm.Issue

  @doc "Returns true when the Kaneo task may be dispatched."
  @spec eligible?(Issue.t(), map()) :: boolean()
  def eligible?(%Issue{} = issue, config) do
    issue.tracker == :kaneo and
      issue.status in Map.get(config, :active_states, [])
  end
end
