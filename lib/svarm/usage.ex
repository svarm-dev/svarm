defmodule Svarm.Usage do
  @moduledoc """
  Public API for usage tracking. The orchestrator, AgentRunner, and
  Decompose call this module to record token consumption.
  """
  alias Svarm.Usage.{Ledger, Outcomes, Query, Rates}

  @doc """
  Append a usage ledger row.

  Accepts a keyword list or map. Prefer keyword lists at call sites so the
  ledger field contract lives only in `normalize_attrs/1`.
  """
  def append(attrs) when is_list(attrs), do: append(Map.new(attrs))

  def append(attrs) when is_map(attrs) do
    Ledger.append(normalize_attrs(attrs))
  end

  @doc """
  Append one gap row when `run_id` has no ledger rows.

  Tokens and `provider_cost_usd` are nil. A second call inserts nothing.
  Not a forecast: budget still sees `0.0`.
  """
  def ensure_attempt_row(entry) when is_map(entry) do
    run_id = entry[:run_id]
    task_id = entry_task_id(entry)

    if is_binary(run_id) and is_binary(task_id) and Ledger.count_for_run(run_id) == 0 do
      append(
        run_id: run_id,
        task_id: task_id,
        tenant: entry[:tenant],
        source: entry_source(entry),
        provider: entry[:provider],
        model_id: entry[:model_id] || entry[:model],
        prompt_tokens: nil,
        completion_tokens: nil,
        provider_cost_usd: nil,
        estimated: true
      )
    end

    :ok
  end

  defp entry_task_id(%{task_id: id}) when is_binary(id), do: id
  defp entry_task_id(%{task: %{id: id}}) when is_binary(id), do: id
  defp entry_task_id(_), do: nil

  defp entry_source(%{source: source}) when is_binary(source) and source != "", do: source
  defp entry_source(_), do: "attempt"

  defdelegate for_task(task_id), to: Ledger
  defdelegate list_all(), to: Ledger
  defdelegate task_cost(task_id), to: Query
  defdelegate task_cost_summary(task_id), to: Query
  defdelegate task_cost_summaries(task_ids), to: Query
  defdelegate session_cost_summary(), to: Query
  defdelegate session_totals(), to: Query
  defdelegate cost_usd(provider, model_id, prompt_tokens, completion_tokens), to: Rates
  defdelegate classify_outcome_status(status), to: Outcomes, as: :classify_status
  defdelegate outcome_buckets(), to: Outcomes, as: :outcomes

  @doc """
  Attribute ledger spend to `:merged` / `:in_review` / `:other` buckets.

  Query-time only — the ledger is append-only. See `Svarm.Usage.Outcomes`
  for bucket definitions (status + GitHub PR `merged`) and honesty limits.
  """
  def by_outcome(opts \\ []), do: Outcomes.by_outcome(opts)

  # Single construction site for ledger field contract (avoids repeated map shapes).
  defp normalize_attrs(attrs) do
    %{
      run_id: Map.fetch!(attrs, :run_id),
      task_id: Map.fetch!(attrs, :task_id),
      tenant: Map.get(attrs, :tenant),
      source: Map.fetch!(attrs, :source),
      provider: Map.get(attrs, :provider),
      model_id: Map.get(attrs, :model_id),
      prompt_tokens: Map.get(attrs, :prompt_tokens),
      completion_tokens: Map.get(attrs, :completion_tokens),
      estimated: Map.get(attrs, :estimated, false),
      provider_cost_usd: coerce_cost(Map.get(attrs, :provider_cost_usd))
    }
  end

  # Ecto :float rejects an integer. Pi reports a zero bill as `0`.
  # nil stays "not reported", not a fake zero.
  defp coerce_cost(n) when is_integer(n), do: n * 1.0
  defp coerce_cost(n) when is_float(n), do: n
  defp coerce_cost(_), do: nil
end
