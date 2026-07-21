defmodule Svarm.Usage.Query do
  @moduledoc """
  Cost aggregation and reporting queries.
  Cost is calculated at query time — never stored.
  """
  alias Svarm.Usage.{Ledger, Rates}

  @doc """
  Returns a per-task cost breakdown with total and source-level detail.
  Use this for the run details panel.
  """
  def task_cost(task_id) do
    records = Ledger.for_task(task_id)

    {total, breakdown} =
      Enum.reduce(records, {0.0, %{}}, fn record, {total_acc, breakdown_acc} ->
        case Rates.cost_usd(
               record.provider,
               record.model_id,
               record.prompt_tokens || 0,
               record.completion_tokens || 0
             ) do
          {:ok, cost} ->
            key = {record.source, record.provider, record.model_id}
            new_total = total_acc + cost
            new_breakdown = Map.update(breakdown_acc, key, cost, &(&1 + cost))
            {new_total, new_breakdown}

          _ ->
            {total_acc, breakdown_acc}
        end
      end)

    %{
      task_id: task_id,
      total_cost_usd: Float.round(total, 4),
      estimated: Enum.any?(records, & &1.estimated),
      breakdown: breakdown,
      record_count: length(records)
    }
  end

  @doc """
  Lightweight summary suitable for displaying on task cards.
  Returns nil if there is no usage data for the task.
  """
  def task_cost_summary(task_id) do
    records = Ledger.for_task(task_id)

    if records == [] do
      nil
    else
      %{
        total_cost_usd: Float.round(sum_usage_cost(records), 4),
        estimated: Enum.any?(records, & &1.estimated),
        record_count: length(records)
      }
    end
  end

  defp sum_usage_cost(records) do
    Enum.reduce(records, 0.0, fn record, acc ->
      case Rates.cost_usd(
             record.provider,
             record.model_id,
             record.prompt_tokens || 0,
             record.completion_tokens || 0
           ) do
        {:ok, cost} -> acc + cost
        _ -> acc
      end
    end)
  end

  @doc """
  Returns a simple session-wide cost total (in USD).
  Useful for the orchestrator status bar.
  """
  def session_cost_summary do
    records = Ledger.list_all()

    total =
      Enum.reduce(records, 0.0, fn record, acc ->
        case Rates.cost_usd(
               record.provider,
               record.model_id,
               record.prompt_tokens || 0,
               record.completion_tokens || 0
             ) do
          {:ok, cost} -> acc + cost
          _ -> acc
        end
      end)

    %{
      total_cost_usd: Float.round(total, 4),
      record_count: length(records)
    }
  end

  @doc """
  Returns aggregate spend grouped by model for a given time period.
  """
  def by_model(since_unix) when is_integer(since_unix) do
    Ledger.for_tenant(nil)
    # For now, query all records since the timestamp
    # Future: add time-based filtering to Ledger
    []
  end

  @doc """
  Returns aggregate spend grouped by tenant (goal).
  """
  def by_tenant do
    # Future: GROUP BY tenant aggregation
    []
  end

  @doc """
  Returns total tokens consumed in the current session.
  """
  def session_totals do
    totals = Ledger.totals_since(0)

    %{
      prompt_tokens: totals[:prompt] || 0,
      completion_tokens: totals[:completion] || 0,
      record_count: totals[:count] || 0
    }
  end
end
