defmodule Svarm.Usage.Query do
  @moduledoc """
  Cost aggregation and reporting queries.

  Preference order per record:
  1. `provider_cost_usd` when the adapter reported a real bill (e.g. OpenRouter)
  2. rate-table estimate from `Svarm.Usage.Rates`
  3. $0 only when both are missing (unknown model + no provider total)

  Session and multi-task summaries use SQL group-by aggregates so the common
  path does not materialize every ledger row in Elixir.
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
    case task_cost_summaries([task_id]) do
      %{^task_id => summary} -> summary
      _ -> nil
    end
  end

  @doc """
  Batched task cost summaries for board/dashboard cards.

  One SQL query (`task_id IN (...)` + group by task/provider/model), then rate
  table applied per group in Elixir. Returns `%{task_id => summary}` for tasks
  that have usage; missing keys mean no ledger rows.
  """
  def task_cost_summaries([]), do: %{}

  def task_cost_summaries(task_ids) when is_list(task_ids) do
    task_ids
    |> Enum.uniq()
    |> Ledger.cost_groups_for_tasks()
    |> Enum.group_by(& &1.task_id)
    |> Map.new(fn {task_id, groups} ->
      {task_id, summarize_task_groups(groups)}
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

  Uses SQL aggregates (group by provider/model), not a full-table load.
  """
  def session_cost_summary do
    Ledger.session_cost_groups() |> summarize_session_groups()
  end

  @doc """
  Spend summary for records whose wall-clock `inserted_at` falls on the
  given UTC calendar day. Rows with nil `inserted_at` are excluded.
  """
  def utc_day_cost_summary(%Date{} = day) do
    Ledger.cost_groups_for_utc_day(day) |> summarize_session_groups()
  end

  @doc """
  Spend summary for records whose wall-clock `inserted_at` is on or after `since`.
  Rows with nil `inserted_at` are excluded.
  """
  def cost_since_inserted_at(%DateTime{} = since) do
    Ledger.cost_groups_since_inserted_at(since) |> summarize_session_groups()
  end

  @doc """
  Per-task spend summaries for records with wall-clock `inserted_at >= since`.

  Returns `%{task_id => summary}` (same shape as `task_cost_summaries/1`).
  Missing keys mean no in-window ledger rows.
  """
  @spec cost_since_by_task(DateTime.t()) :: %{optional(String.t()) => map()}
  def cost_since_by_task(%DateTime{} = since) do
    Ledger.task_cost_groups_since_inserted_at(since)
    |> Enum.group_by(& &1.task_id)
    |> Map.new(fn {task_id, groups} ->
      {task_id, summarize_task_groups(groups)}
    end)
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
  Derived from the same SQL aggregate as session cost (no second scan).
  """
  def session_totals do
    summary = session_cost_summary()
    totals_from_summary(summary)
  end

  @doc """
  Token totals map derived from a session (or window) cost summary.
  Avoids a second ledger scan when the summary is already in hand.
  """
  def totals_from_summary(%{
        prompt_tokens: prompt,
        completion_tokens: completion,
        record_count: count
      }) do
    %{
      prompt_tokens: prompt,
      completion_tokens: completion,
      record_count: count
    }
  end

  # --- private: SQL group → summary maps ---

  defp summarize_task_groups(groups) do
    {total, count, estimated} =
      Enum.reduce(groups, {0.0, 0, false}, fn group, {total_acc, count_acc, est_acc} ->
        cost = group_cost_usd(group)
        count = count_acc + (group.record_count || 0)
        estimated = est_acc or unbilled?(group)
        {total_acc + cost, count, estimated}
      end)

    %{
      total_cost_usd: Float.round(total, 4),
      estimated: estimated,
      record_count: count
    }
  end

  defp summarize_session_groups(groups) do
    {total, prompt, completion, count, estimated} =
      Enum.reduce(groups, {0.0, 0, 0, 0, false}, fn group,
                                                    {total_acc, p_acc, c_acc, n_acc, est_acc} ->
        cost = group_cost_usd(group)

        {
          total_acc + cost,
          p_acc + (group.prompt_tokens || 0),
          c_acc + (group.completion_tokens || 0),
          n_acc + (group.record_count || 0),
          est_acc or unbilled?(group)
        }
      end)

    %{
      total_cost_usd: Float.round(total, 4),
      record_count: count,
      prompt_tokens: prompt,
      completion_tokens: completion,
      estimated: estimated
    }
  end

  defp group_cost_usd(group) do
    billed = as_float(group.billed_usd)

    rate =
      case Rates.cost_usd(
             group.provider,
             group.model_id,
             group.rate_prompt || 0,
             group.rate_completion || 0
           ) do
        {:ok, cost} -> cost
        _ -> 0.0
      end

    billed + rate
  end

  defp as_float(nil), do: 0.0
  defp as_float(n) when is_float(n), do: n
  defp as_float(n) when is_integer(n), do: n * 1.0

  # Any row without provider-reported USD is estimated (rate table or unknown).
  defp unbilled?(group), do: (group.unbilled_count || 0) > 0
end
