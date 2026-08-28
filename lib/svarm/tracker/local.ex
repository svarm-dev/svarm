defmodule Svarm.Tracker.Local do
  @moduledoc """
  Local kanban tracker adapter. Wraps `Svarm.KanbanBridge` behind the
  `Svarm.Tracker` behaviour. This is the default tracker (kind: local).
  """
  @behaviour Svarm.Tracker

  alias Svarm.KanbanBridge
  alias Svarm.Tracker.Local.Eligibility
  alias Svarm.Tracker.Local.Normalize

  @impl true
  def list_eligible(config) do
    active_states = Map.get(config, :active_states, ["todo", "in_progress"])

    candidates =
      KanbanBridge.fetch_eligible(active_states)
      |> Normalize.from_maps()
      |> Enum.filter(&Eligibility.eligible?(&1, config))

    {:ok, candidates}
  end

  @impl true
  def get_issue(_config, id) do
    case KanbanBridge.get_task(id) do
      nil -> {:error, :not_found}
      map -> {:ok, Normalize.from_map(map)}
    end
  end

  @impl true
  def get_issues(_config, []), do: {:ok, %{}}

  def get_issues(_config, ids) when is_list(ids) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    found = KanbanBridge.get_tasks(ids)

    results =
      Map.new(ids, fn id ->
        case Map.fetch(found, id) do
          {:ok, map} -> {id, {:ok, Normalize.from_map(map)}}
          :error -> {id, {:error, :not_found}}
        end
      end)

    {:ok, results}
  end

  @impl true
  def list_issues(_config, filters \\ []) do
    {include_body, filters} = Keyword.pop(filters, :include_body, true)

    issues =
      KanbanBridge.list_tasks(filters, include_body: include_body)
      |> Normalize.from_maps()

    {:ok, issues}
  end

  @impl true
  def create_issue(_config, attrs) do
    {:ok,
     KanbanBridge.create_task(attrs)
     |> then(&Normalize.from_map/1)}
  end

  @impl true
  def update_status(_config, id, status) do
    KanbanBridge.update_status(id, status)
  end

  @impl true
  def update_attempts(_config, id, attempts) do
    KanbanBridge.update_attempts(id, attempts)
  end

  @impl true
  def claim(_config, _id), do: :ok

  @impl true
  def delete_all(_config) do
    KanbanBridge.delete_all_tasks()
  end

  @impl true
  def post_run_summary(_config, _id, _summary), do: :ok

  @impl true
  def capabilities, do: []
end
