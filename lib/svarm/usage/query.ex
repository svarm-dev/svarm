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
  Returns a session-wide spend summary: cost, tokens, and estimate flag.
  Useful for the orchestrator status bar and dashboard cost card.
  """
  def session_cost_summary do
    Ledger.list_all() |> summarize_records()
  end

  @doc """
  Returns spend summary for records since a monotonic timestamp (ms).
  Uses model-specific pricing from Rates — no flat-rate estimation.
  """
  def cost_since(since_mono) when is_integer(since_mono) do
    Ledger.records_since(since_mono) |> summarize_records()
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

  Prefer `session_cost_summary/0` when cost and tokens must stay aligned.
  """
  def session_totals do
    summary = session_cost_summary()

    %{
      prompt_tokens: summary.prompt_tokens,
      completion_tokens: summary.completion_tokens,
      record_count: summary.record_count
    }
  end

  defp summarize_records(records) do
    %{
      total_cost_usd: Float.round(sum_usage_cost(records), 4),
      record_count: length(records),
      prompt_tokens: Enum.reduce(records, 0, &((&1.prompt_tokens || 0) + &2)),
      completion_tokens: Enum.reduce(records, 0, &((&1.completion_tokens || 0) + &2)),
      estimated: Enum.any?(records, & &1.estimated)
    }
  end
end
