defmodule Svarm.Budget do
  @moduledoc """
  Hard spend caps at preflight/dispatch.

  Caps come from env (`SVARM_BUDGET_MAX_USD_PER_TICKET`, `SVARM_BUDGET_MAX_USD_PER_DAY`)
  and optional WORKFLOW front matter (`budget.max_usd_per_ticket`, `budget.max_usd_per_day`).
  When both sources set a field, the **stricter** (lower) value wins.
  Unset fields are ignored (no hard stop for that scope).

  Cost basis matches `Usage.Query.cost_for_record/1` (provider USD, else rate table).
  Estimated rows **count** toward the cap (fail closed on spend).
  """

  alias Svarm.Usage.Query

  @type caps :: %{
          optional(:max_usd_per_ticket) => float(),
          optional(:max_usd_per_day) => float()
        }

  @type exceed_meta :: %{scope: :ticket | :day, cap: float(), spent: float()}

  @doc """
  Load caps from process env and optional WORKFLOW config map (string keys).

  `workflow_config` is raw front-matter (as from `Workflow.config`) or nil.
  """
  @spec load_caps(map() | nil) :: caps()
  def load_caps(workflow_config \\ nil) do
    env_ticket = parse_float(System.get_env("SVARM_BUDGET_MAX_USD_PER_TICKET"))
    env_day = parse_float(System.get_env("SVARM_BUDGET_MAX_USD_PER_DAY"))

    wf_ticket = workflow_float(workflow_config, "max_usd_per_ticket")
    wf_day = workflow_float(workflow_config, "max_usd_per_day")

    %{}
    |> maybe_put(:max_usd_per_ticket, stricter(env_ticket, wf_ticket))
    |> maybe_put(:max_usd_per_day, stricter(env_day, wf_day))
  end

  @doc """
  Check whether a new spawn is allowed for `task_id` under `caps`.

  Returns `:ok` or `{:error, :budget_exceeded, meta}`.
  """
  @spec check(String.t(), caps()) :: :ok | {:error, :budget_exceeded, exceed_meta()}
  def check(task_id, caps) when is_binary(task_id) and is_map(caps) do
    case check_ticket(task_id, Map.get(caps, :max_usd_per_ticket)) do
      :ok -> check_day(Map.get(caps, :max_usd_per_day))
      error -> error
    end
  end

  defp check_ticket(_task_id, nil), do: :ok

  defp check_ticket(task_id, cap) when is_number(cap) do
    spent =
      case Query.task_cost_summary(task_id) do
        %{total_cost_usd: usd} when is_number(usd) -> usd * 1.0
        _ -> 0.0
      end

    if spent >= cap do
      {:error, :budget_exceeded, %{scope: :ticket, cap: cap * 1.0, spent: spent}}
    else
      :ok
    end
  end

  defp check_day(nil), do: :ok

  defp check_day(cap) when is_number(cap) do
    summary = Query.utc_day_cost_summary(Date.utc_today())
    spent = summary.total_cost_usd * 1.0

    if spent >= cap do
      {:error, :budget_exceeded, %{scope: :day, cap: cap * 1.0, spent: spent}}
    else
      :ok
    end
  end

  defp workflow_float(nil, _key), do: nil

  defp workflow_float(config, key) when is_map(config) and is_binary(key) do
    budget =
      case Map.get(config, "budget") do
        %{} = b -> b
        _ -> %{}
      end

    parse_float(Map.get(budget, key))
  end

  defp stricter(nil, nil), do: nil
  defp stricter(a, nil), do: a
  defp stricter(nil, b), do: b
  defp stricter(a, b), do: min(a, b)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_float(nil), do: nil
  defp parse_float(n) when is_float(n), do: n
  defp parse_float(n) when is_integer(n), do: n * 1.0

  defp parse_float(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp parse_float(_), do: nil
end
