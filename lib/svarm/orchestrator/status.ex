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
      Map.new(state.running, fn {_key, entry} -> {task_id(entry), entry.started_mono_ms} end)

    %{
      poll_interval_ms: state.poll_interval_ms,
      max_concurrent: state.max_concurrent,
      approval: state.approval,
      running: map_size(state.running),
      claimed: MapSet.size(state.claimed),
      retrying: map_size(state.retry_attempts),
      completed: MapSet.size(state.completed),
      running_ids: Enum.map(state.running, fn {_key, entry} -> task_id(entry) end),
      retry_ids: Enum.map(state.retry_attempts, fn {_key, entry} -> task_id(entry) end),
      active_assignees: active_assignees,
      active_agent_count: length(active_assignees),
      running_started: running_started,
      last_tick_mono_ms: state.last_tick_mono_ms,
      budget_caps: state.budget_caps || %{},
      budget_mode: state.budget_mode || :hard,
      last_budget_block: state.last_budget_block,
      ci_resume: state.ci_resume_caps || %{enabled: false},
      review_resume: state.review_resume_caps || %{enabled: false},
      board_ids: running_board_ids(state)
    }
  end

  # Board-facing ids are public task ids, never the scoped run keys: the board
  # matches cards by id, and after import the keys are {board_id, external_id}.
  defp task_id(entry) do
    Map.get(entry, :issue_id) || row_id(Map.get(entry, :task)) ||
      binary_id(Map.get(entry, :identifier))
  end

  defp row_id(%{} = task), do: Map.get(task, :id)
  defp row_id(_), do: nil

  defp binary_id(id) when is_binary(id), do: id
  defp binary_id(_), do: nil

  defp running_board_ids(state) do
    state.running
    |> Enum.flat_map(fn
      {{board_id, _ext}, _entry} when is_binary(board_id) -> [board_id]
      {_key, %{board_id: board_id}} when is_binary(board_id) -> [board_id]
      _ -> []
    end)
    |> Enum.uniq()
  end
end
