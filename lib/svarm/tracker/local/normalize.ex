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
      # local: source_id == id
      source_id: map[:id],
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
