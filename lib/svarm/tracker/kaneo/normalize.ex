defmodule Svarm.Tracker.Kaneo.Normalize do
  @moduledoc """
  Converts Kaneo API board/task payloads to `%Svarm.Issue{}` structs.

  Kaneo has no native retry counter. `from_task/2` sets `attempts: 0` and
  `attach_attempts/1` overlays `task_coordination.attempts` (SQLite, same
  durable store GitHub uses), so retries increment and exhaust across
  re-fetches without writing anything back to Kaneo.

  A task's Svärm status is the orchestrator name for its Kaneo column
  (`Svarm.Tracker.Kaneo.Columns`). Stock slugs `to-do` and `in-progress`
  become `todo` and `in_progress`.
  """
  alias Svarm.Issue
  alias Svarm.Tracker.Kaneo.Columns
  alias Svarm.Tracker.NormalizeSupport

  @priority_to_int %{
    "urgent" => 4,
    "high" => 3,
    "medium" => 2,
    "low" => 1,
    "no-priority" => 0
  }

  @int_to_priority %{4 => "urgent", 3 => "high", 2 => "medium", 1 => "low"}

  @doc "Convert a single Kaneo task map to an Issue struct."
  @spec from_task(map(), map()) :: Issue.t()
  def from_task(task, config) when is_map(task) do
    labels = label_names(task)

    %Issue{
      id: task["id"],
      source_id: task["id"],
      title: task["title"],
      body: task["description"],
      type: infer_type(labels),
      assignee: assignee(task),
      status: Columns.to_status(task["status"], config),
      priority: priority(task["priority"]),
      attempts: 0,
      created_by: task["userId"] || "kaneo",
      created_at: NormalizeSupport.created_unix(task["createdAt"]),
      tenant: task["projectId"],
      labels: labels,
      depends_on: [],
      follow_up: nil,
      tracker: :kaneo,
      raw: task
    }
  end

  @doc """
  Flatten a `GET /api/task/tasks/{projectId}` board response into task maps.

  Includes each column's tasks plus the archived and planned buckets.
  """
  @spec board_tasks(term()) :: [map()]
  def board_tasks(%{"data" => %{"columns" => columns}} = board) when is_list(columns) do
    column_tasks = Enum.flat_map(columns, &List.wrap(&1["tasks"]))

    column_tasks ++
      List.wrap(get_in(board, ["data", "archivedTasks"])) ++
      List.wrap(get_in(board, ["data", "plannedTasks"]))
  end

  def board_tasks(_), do: []

  @doc "Normalize every task in a board response."
  @spec from_board(term(), map()) :: [Issue.t()]
  def from_board(board, config) do
    board
    |> board_tasks()
    |> Enum.map(&from_task(&1, config))
  end

  @doc "Overlay durable retry counters for one issue or many."
  defdelegate attach_attempts(issues), to: NormalizeSupport

  @doc "Map a Svärm integer priority to a Kaneo priority string."
  @spec to_api_priority(term()) :: String.t()
  def to_api_priority(n) when is_integer(n), do: Map.get(@int_to_priority, n, "no-priority")
  def to_api_priority(_), do: "no-priority"

  defp priority(p) when is_binary(p), do: Map.get(@priority_to_int, p, 0)
  defp priority(_), do: 0

  defp assignee(task) do
    case task["assigneeName"] || task["userId"] do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp label_names(%{"labels" => labels}) when is_list(labels) do
    Enum.flat_map(labels, fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp label_names(_), do: []

  defp infer_type(labels) do
    cond do
      "research" in labels -> "research"
      "docs" in labels -> "docs"
      true -> "code"
    end
  end
end
