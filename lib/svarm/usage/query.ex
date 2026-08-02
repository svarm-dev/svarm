defmodule Svarm.Usage.Query do
  @moduledoc """
  Cost aggregation and reporting queries.

  Preference order per record:
  1. `provider_cost_usd` when the adapter reported a real bill (e.g. OpenRouter)
  2. rate-table estimate from `Svarm.Usage.Rates`
  3. $0 only when both are missing (unknown model + no provider total)
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
        case cost_for_record(record) do
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
      estimated: Enum.any?(records, &estimated_record?/1),
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
        estimated: Enum.any?(records, &estimated_record?/1),
        record_count: length(records)
      }
    end
  end

  defp sum_usage_cost(records) do
    Enum.reduce(records, 0.0, fn record, acc ->
      case cost_for_record(record) do
        {:ok, cost} -> acc + cost
        _ -> acc
      end
    end)
  end

  @doc """
  Cost for one ledger row: prefer provider-reported USD, else rate table.
  """
  def cost_for_record(%{provider_cost_usd: cost} = _record)
      when is_number(cost) do
    {:ok, cost * 1.0}
  end

  def cost_for_record(record) do
    Rates.cost_usd(
      record.provider,
      record.model_id,
      record.prompt_tokens || 0,
      record.completion_tokens || 0
    )
  end

  @doc """
  Whether a ledger row's dollars are approximate.

  - Provider-reported `provider_cost_usd` → exact (not estimated)
  - Explicit `estimated: true` → estimated
  - Rate-table / incomplete rows → estimated (fail closed on honesty)
  """
  def estimated_record?(%{provider_cost_usd: cost}) when is_number(cost), do: false
  def estimated_record?(%{estimated: true}), do: true
  def estimated_record?(_), do: true

  @doc """
  Returns a session-wide spend summary: cost, tokens, and estimate flag.
  Useful for the orchestrator status bar and dashboard cost card.
  """
  def session_cost_summary do
    Ledger.list_all() |> summarize_records()
  end

  @doc """
  Spend summary for records whose wall-clock `inserted_at` falls on the
  given UTC calendar day. Rows with nil `inserted_at` are excluded.
  """
  def utc_day_cost_summary(%Date{} = day) do
    Ledger.for_utc_day(day) |> summarize_records()
  end

  @doc """
  Returns spend summary for records since a monotonic timestamp (ms).
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
      estimated: Enum.any?(records, &estimated_record?/1)
    }
  end
end
