defmodule Svarm.Orchestrator.Status do
  @moduledoc """
  Board-facing orchestrator status snapshot and PubSub broadcast.

  `summary/1` is what `Svarm.Orchestrator.status/0` returns. Secrets stay
  out of this map — agents and tracker config are not included.
  """

  alias Svarm.Events

  @doc false
  def broadcast(state) do
    Events.broadcast_orchestrator_status(summary(state))
  end

  @doc false
  def summary(state) do
    active_assignees =
      state.running
      |> Enum.map(fn {_id, entry} -> entry.task.assignee end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    running_started =
      Map.new(state.running, fn {id, entry} -> {id, entry.started_mono_ms} end)

    %{
      poll_interval_ms: state.poll_interval_ms,
      max_concurrent: state.max_concurrent,
      approval: state.approval,
      running: map_size(state.running),
      claimed: MapSet.size(state.claimed),
      retrying: map_size(state.retry_attempts),
      completed: MapSet.size(state.completed),
      running_ids: Map.keys(state.running),
      retry_ids: Map.keys(state.retry_attempts),
      active_assignees: active_assignees,
      active_agent_count: length(active_assignees),
      running_started: running_started,
      last_tick_mono_ms: state.last_tick_mono_ms,
      budget_caps: state.budget_caps || %{},
      budget_mode: state.budget_mode || :hard,
      last_budget_block: state.last_budget_block,
      ci_resume: state.ci_resume_caps || %{enabled: false},
      review_resume: state.review_resume_caps || %{enabled: false}
    }
  end
end
