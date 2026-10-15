defmodule Svarm.Usage.Query do
  @moduledoc """
  Cost aggregation and reporting queries.

  Preference order per record:
  1. `provider_cost_usd` when the adapter reported a real bill (e.g. OpenRouter)
  2. rate-table estimate from `Svarm.Usage.Rates`
  3. $0 only when both are missing (unknown model + no provider total)

  Session, multi-task, and per-task totals use SQL group-by aggregates so the
  common path does not materialize every ledger row in Elixir. Run-detail
  `{source, provider, model_id}` breakdown is a separate grouped query, not a
  full row load.

  Summaries also carry `unmetered_rows` and `unpriced_rows`. Those counters
  do not change `total_cost_usd`.
  """
  alias Svarm.Usage.{Ledger, Rates}

  @doc """
  Returns a per-task cost breakdown with total and source-level detail.
  Use this for the run details panel.

  Totals (`total_cost_usd`, `record_count`, `estimated`, token sums) come from
  the same grouped SQL path as `task_cost_summaries/1`. Breakdown is a bounded
  group-by, not `Ledger.for_task/1`.
  """
  def task_cost(task_id) do
    groups = Ledger.cost_groups_for_tasks([task_id])
    totals = summarize_groups(groups)

    Map.merge(totals, %{
      task_id: task_id,
      breakdown: breakdown_for_task(task_id, totals.record_count)
    })
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
      {task_id, summarize_groups(groups)}
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
  An empty ledger returns a zero summary, including the coverage counters.
  """
  def session_cost_summary do
    Ledger.session_cost_groups() |> summarize_groups()
  end

  @doc """
  Spend summary for records whose wall-clock `inserted_at` falls on the
  given UTC calendar day. Rows with nil `inserted_at` are excluded.
  """
  def utc_day_cost_summary(%Date{} = day) do
    Ledger.cost_groups_for_utc_day(day) |> summarize_groups()
  end

  @doc """
  Spend summary for records whose wall-clock `inserted_at` is on or after `since`.
  Rows with nil `inserted_at` are excluded.
  """
  def cost_since_inserted_at(%DateTime{} = since) do
    Ledger.cost_groups_since_inserted_at(since) |> summarize_groups()
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
      {task_id, summarize_groups(groups)}
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

  @doc """
  Fold SQL cost groups into one summary.

  `total_cost_usd` is billed dollars plus the rate table. Unknown models add
  `0.0`. `unmetered_rows` counts null-bill rows with zero tokens.
  `unpriced_rows` counts unbilled token rows whose `Rates.cost_usd/4` returns
  `{:error, :unknown_model}`.
  """
  def summarize_groups(groups) when is_list(groups) do
    groups
    |> Enum.reduce(empty_summary(), fn group, acc ->
      %{
        total_cost_usd: acc.total_cost_usd + group_cost_usd(group),
        estimated: acc.estimated or unbilled?(group),
        record_count: acc.record_count + (group.record_count || 0),
        unmetered_rows: acc.unmetered_rows + (group.unmetered_count || 0),
        unpriced_rows: acc.unpriced_rows + unpriced_count(group),
        prompt_tokens: acc.prompt_tokens + (group.prompt_tokens || 0),
        completion_tokens: acc.completion_tokens + (group.completion_tokens || 0)
      }
    end)
    |> Map.update!(:total_cost_usd, &Float.round(&1, 4))
  end

  defp empty_summary do
    %{
      total_cost_usd: 0.0,
      estimated: false,
      record_count: 0,
      unmetered_rows: 0,
      unpriced_rows: 0,
      prompt_tokens: 0,
      completion_tokens: 0
    }
  end

  defp breakdown_for_task(_task_id, 0), do: %{}

  defp breakdown_for_task(task_id, _record_count) do
    task_id
    |> Ledger.breakdown_groups_for_task()
    |> Map.new(fn group ->
      {{group.source, group.provider, group.model_id}, group_cost_usd(group)}
    end)
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

  # A known model, including a zero rate, is not unpriced. Zero unbilled tokens
  # are unmetered, not an unknown price.
  defp unpriced_count(group) do
    tokens = (group.rate_prompt || 0) + (group.rate_completion || 0)

    if tokens > 0 and unknown_model?(group) do
      max((group.unbilled_count || 0) - (group.unmetered_count || 0), 0)
    else
      0
    end
  end

  defp unknown_model?(group) do
    match?(
      {:error, :unknown_model},
      Rates.cost_usd(
        group.provider,
        group.model_id,
        group.rate_prompt || 0,
        group.rate_completion || 0
      )
    )
  end
end
