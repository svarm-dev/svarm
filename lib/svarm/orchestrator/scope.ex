defmodule Svarm.Orchestrator.Scope do
  @moduledoc """
  Board scope for the single orchestrator process.

  No catalog revision keeps today's keys (`task.id`) and one tracker.
  After import, running, claimed, approved_once, and retry keys are
  `{board_id, external_task_id}`. A bare external id is not a key.
  """

  alias Svarm.Settings.Catalog.Store, as: CatalogStore

  @doc false
  def refresh(state) do
    %{state | catalog: load_catalog()}
  end

  @doc false
  def catalog?(%{catalog: %{revision: rev}}) when is_integer(rev), do: true
  def catalog?(_), do: false

  @doc "Enabled catalog boards, or `:legacy` when no revision exists."
  def enabled_boards(%{catalog: %{boards: boards}}) when is_list(boards) do
    Enum.filter(boards, &(&1.enabled == true))
  end

  def enabled_boards(_), do: :legacy

  @doc false
  def run_key(state, task) do
    if catalog?(state) do
      {board_id(task), external_id(task)}
    else
      id(task)
    end
  end

  @doc false
  def external_id(task) when is_map(task) do
    Map.get(task, :external_task_id) || Map.get(task, :source_id) || Map.get(task, :id)
  end

  @doc false
  def board_id(task) when is_map(task), do: Map.get(task, :board_id)

  @doc false
  def id(task) when is_map(task), do: Map.get(task, :id)

  @doc """
  Admit a new run. Caps only refuse the new admit. Nothing running is removed.
  """
  def admit?(state, task) when is_map(task) do
    running = state.running || %{}
    key = run_key(state, task)

    not Map.has_key?(running, key) and
      map_size(running) < instance_cap(state) and
      board_under_cap?(state, board_id(task))
  end

  @doc false
  def instance_cap(%{max_concurrent: n}) when is_integer(n), do: n
  def instance_cap(_), do: 3

  @doc false
  def board_cap(%{catalog: %{boards: boards}}, board_id) when is_binary(board_id) do
    case Enum.find(boards, &(&1.id == board_id)) do
      %{max_concurrent: n} when is_integer(n) -> n
      _ -> nil
    end
  end

  def board_cap(_, _), do: nil

  defp load_catalog do
    case CatalogStore.latest_revision() do
      rev when is_integer(rev) ->
        case CatalogStore.get(rev) do
          {:ok, snap} -> %{revision: rev, boards: snap.boards || []}
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp board_under_cap?(state, board_id) do
    case board_cap(state, board_id) do
      nil -> true
      cap -> board_running(state, board_id) < cap
    end
  end

  defp board_running(state, board_id) do
    Enum.count(state.running || %{}, fn
      {{^board_id, _ext}, _entry} -> true
      {_key, %{board_id: ^board_id}} -> true
      _ -> false
    end)
  end
end
