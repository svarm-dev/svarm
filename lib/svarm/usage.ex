defmodule Svarm.Usage do
  @moduledoc """
  Public API for usage tracking. The orchestrator, AgentRunner, and
  Decompose call this module to record token consumption.
  """
  alias Svarm.Usage.{Ledger, Query, Rates}

  defdelegate append(attrs), to: Ledger
  defdelegate for_task(task_id), to: Ledger
  defdelegate list_all(), to: Ledger
  defdelegate task_cost(task_id), to: Query
  defdelegate task_cost_summary(task_id), to: Query
  defdelegate session_cost_summary(), to: Query
  defdelegate session_totals(), to: Query
  defdelegate cost_usd(provider, model_id, prompt_tokens, completion_tokens), to: Rates
end
