defmodule Svarm.Tracker.Local.Normalize do
  @moduledoc """
  Converts KanbanBridge map representations to `%Svarm.Issue{}` structs.
  The local tracker's "external" format is the plain maps returned by
  KanbanBridge GenServer calls.
  """
  alias Svarm.Issue

  @doc """
  Convert a KanbanBridge map to an Issue struct.
  """
  def from_map(map) when is_map(map) do
    %Issue{
      id: map[:id],
      # Pre-import rows copy external_task_id from id, so source_id stays the
      # legacy workspace key. A shared external id is not the row id.
      source_id: map[:external_task_id] || map[:id],
      board_id: map[:board_id],
      external_task_id: map[:external_task_id] || map[:id],
      workspace_locator: map[:workspace_locator],
      title: map[:title],
      body: map[:body],
      type: map[:type] || "code",
      assignee: map[:assignee],
      status: map[:status] || "todo",
      priority: map[:priority] || 0,
      attempts: map[:attempts] || 0,
      created_by: map[:created_by],
      created_at: map[:created_at],
      tenant: map[:tenant],
      labels: Map.get(map, :labels, []),
      depends_on: Map.get(map, :depends_on, []),
      wait_reason: Map.get(map, :wait_reason),
      pending_question: Map.get(map, :pending_question),
      follow_up: Map.get(map, :follow_up),
      tracker: :local,
      raw: map
    }
  end

  @doc """
  Convert a list of KanbanBridge maps to Issue structs.
  """
  def from_maps(maps) when is_list(maps) do
    Enum.map(maps, &from_map/1)
  end
end
