defmodule Svarm.Usage do
  @moduledoc """
  Public API for usage tracking. The orchestrator, AgentRunner, and
  Decompose call this module to record token consumption.
  """
  alias Svarm.Usage.{Ledger, Query, Rates}

  @doc """
  Append a usage ledger row.

  Accepts a keyword list or map. Prefer keyword lists at call sites so the
  ledger field contract lives only in `normalize_attrs/1`.
  """
  def append(attrs) when is_list(attrs), do: append(Map.new(attrs))

  def append(attrs) when is_map(attrs) do
    Ledger.append(normalize_attrs(attrs))
  end

  defdelegate for_task(task_id), to: Ledger
  defdelegate list_all(), to: Ledger
  defdelegate task_cost(task_id), to: Query
  defdelegate task_cost_summary(task_id), to: Query
  defdelegate session_cost_summary(), to: Query
  defdelegate session_totals(), to: Query
  defdelegate cost_usd(provider, model_id, prompt_tokens, completion_tokens), to: Rates

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
      provider_cost_usd: Map.get(attrs, :provider_cost_usd)
    }
  end
end
