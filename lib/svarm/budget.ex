defmodule Svarm.Budget do
  @moduledoc """
  Spend caps at preflight/dispatch.

  Caps come from env (`SVARM_BUDGET_MAX_USD_PER_TICKET`, `SVARM_BUDGET_MAX_USD_PER_DAY`)
  and optional WORKFLOW front matter (`budget.max_usd_per_ticket`, `budget.max_usd_per_day`).
  When both sources set a field, the **stricter** (lower) value wins.
  Unset fields are ignored (no hard stop for that scope).

  Mode (`SVARM_BUDGET_MODE` / WORKFLOW `budget.mode`): `hard` (default) skips
  the spawn; `hold` parks the ticket for a one-shot overage approval.

  Cost basis matches `Usage.Query.cost_for_record/1` (provider USD, else rate table).
  Estimated rows **count** toward the cap (fail closed on spend).
  """

  alias Svarm.{Approval, Coordination, Events, KanbanBridge, Orchestrator}
  alias Svarm.Usage.Query

  @wait_overage "budget_overage"

  @type caps :: %{
          optional(:max_usd_per_ticket) => float(),
          optional(:max_usd_per_day) => float()
        }

  @type exceed_meta :: %{scope: :ticket | :day, cap: float(), spent: float()}
  @type mode :: :hard | :hold

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
  Load over-cap mode. Env `SVARM_BUDGET_MODE` wins over WORKFLOW `budget.mode`.
  Default and unknown values are `:hard`.
  """
  @spec load_mode(map() | nil) :: mode()
  def load_mode(workflow_config \\ nil) do
    env = System.get_env("SVARM_BUDGET_MODE") |> blank_to_nil()
    wf = workflow_string(workflow_config, "mode")
    parse_mode(env || wf)
  end

  @doc "Durable wait_reason string for over-budget holds."
  @spec wait_reason() :: String.t()
  def wait_reason, do: @wait_overage

  @doc "True when this task is parked for overage approval."
  @spec held?(String.t()) :: boolean()
  def held?(task_id) when is_binary(task_id) do
    kanban_held?(task_id) or coord_held?(task_id)
  end

  @doc "Persist over-budget wait on kanban + coordination (GitHub cards)."
  @spec persist_hold(String.t()) :: :ok
  def persist_hold(task_id) when is_binary(task_id) do
    _ = KanbanBridge.update_wait_reason(task_id, @wait_overage)
    _ = Coordination.upsert(task_id, %{wait_reason: @wait_overage})
    :ok
  end

  @doc "Clear over-budget wait fields."
  @spec clear_hold(String.t()) :: :ok
  def clear_hold(task_id) when is_binary(task_id) do
    _ = KanbanBridge.update_wait_reason(task_id, nil)
    _ = Coordination.upsert(task_id, %{wait_reason: nil})
    :ok
  end

  @doc """
  Human unlock: move the ticket back to `todo` and permit **one** subsequent spawn.
  """
  @spec approve_overage(String.t()) :: :ok | {:error, :not_held | :not_found}
  def approve_overage(task_id) when is_binary(task_id) do
    if held?(task_id) do
      # Permit first (sync) so a concurrent tick cannot re-park before overage_once lands.
      Orchestrator.mark_overage_approved(task_id)
      clear_hold(task_id)
      Approval.tracker().update_status(Approval.tracker_config(), task_id, "todo")

      Events.broadcast_task_updated(%{
        id: task_id,
        status: "todo",
        wait_reason: nil,
        reason: :budget_overage
      })

      :ok
    else
      case KanbanBridge.get_task(task_id) do
        nil -> {:error, :not_found}
        _ -> {:error, :not_held}
      end
    end
  end

  @doc "User-facing flash for `approve_overage/1` errors."
  def flash_error(:not_found), do: "Task not found."
  def flash_error(:not_held), do: "Task is not waiting on a budget overage approval."
  def flash_error(other), do: "Could not approve overage (#{inspect(other)})."

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
        %{total_cost_usd: usd} when is_number(usd) -> as_float(usd)
        _ -> 0.0
      end

    if spent >= cap do
      {:error, :budget_exceeded, %{scope: :ticket, cap: as_float(cap), spent: spent}}
    else
      :ok
    end
  end

  defp check_day(nil), do: :ok

  defp check_day(cap) when is_number(cap) do
    summary = Query.utc_day_cost_summary(Date.utc_today())
    spent = as_float(summary.total_cost_usd)

    if spent >= cap do
      {:error, :budget_exceeded, %{scope: :day, cap: as_float(cap), spent: spent}}
    else
      :ok
    end
  end

  defp as_float(n) when is_float(n), do: n
  defp as_float(n) when is_integer(n), do: :erlang.float(n)

  defp kanban_held?(task_id) do
    match?(%{wait_reason: @wait_overage}, KanbanBridge.get_task(task_id))
  end

  defp coord_held?(task_id) do
    match?(%{wait_reason: @wait_overage}, Coordination.get(task_id))
  end

  defp workflow_budget(nil), do: %{}

  defp workflow_budget(config) when is_map(config) do
    case Map.get(config, "budget") do
      %{} = b -> b
      _ -> %{}
    end
  end

  defp workflow_float(config, key), do: parse_float(Map.get(workflow_budget(config), key))

  defp workflow_string(config, key) do
    case Map.get(workflow_budget(config), key) do
      s when is_binary(s) -> s
      atom when is_atom(atom) and not is_nil(atom) -> Atom.to_string(atom)
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  defp parse_mode("hard"), do: :hard
  defp parse_mode("hold"), do: :hold

  defp parse_mode(other) when is_binary(other) do
    case String.downcase(String.trim(other)) do
      "hold" -> :hold
      _ -> :hard
    end
  end

  defp parse_mode(_), do: :hard

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
