defmodule Svarm.Events do
  @moduledoc """
  PubSub topics for the LiveView board.
  """
  @topic "board"

  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(Svarm.PubSub, @topic)
  end

  def broadcast_task_updated(task) when is_map(task) do
    broadcast({:task_updated, task})
  end

  def broadcast_tasks_snapshot(tasks) when is_list(tasks) do
    broadcast({:tasks_snapshot, tasks})
  end

  def broadcast_orchestrator_status(status) when is_map(status) do
    broadcast({:orchestrator_status, status})
  end

  def broadcast_agent_line(task_id, line) when is_binary(task_id) and is_binary(line) do
    broadcast({:agent_line, task_id, line})
  end

  def broadcast_run_started(task_id, meta) when is_map(meta) do
    broadcast({:run_started, task_id, meta})
  end

  def broadcast_run_finished(task_id, exit_code) when is_integer(exit_code) do
    broadcast({:run_finished, task_id, exit_code})
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Svarm.PubSub, @topic, message)
  end
end
