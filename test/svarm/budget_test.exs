defmodule Svarm.BudgetTest do
  use ExUnit.Case, async: false

  alias Svarm.Budget
  alias Svarm.Repo
  alias Svarm.Usage

  setup do
    Repo.delete_all("usage_records")

    prev_ticket = System.get_env("SVARM_BUDGET_MAX_USD_PER_TICKET")
    prev_day = System.get_env("SVARM_BUDGET_MAX_USD_PER_DAY")
    prev_mode = System.get_env("SVARM_BUDGET_MODE")

    on_exit(fn ->
      restore_env("SVARM_BUDGET_MAX_USD_PER_TICKET", prev_ticket)
      restore_env("SVARM_BUDGET_MAX_USD_PER_DAY", prev_day)
      restore_env("SVARM_BUDGET_MODE", prev_mode)
    end)

    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  test "unpriced and missing rows do not count, a rate-table row still does" do
    task_id = "budget_unmeasured"

    Usage.append(%{
      run_id: "run_gap",
      task_id: task_id,
      source: "attempt",
      provider: nil,
      model_id: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      provider_cost_usd: nil,
      estimated: true
    })

    Usage.append(%{
      run_id: "run_unpriced",
      task_id: task_id,
      source: "worker",
      provider: "openrouter",
      model_id: "no-such-model",
      prompt_tokens: 80_000,
      completion_tokens: 4_000,
      provider_cost_usd: nil,
      estimated: true
    })

    summary = Usage.task_cost_summary(task_id)
    assert summary.total_cost_usd == 0.0
    assert summary.unmetered_rows == 1
    assert summary.unpriced_rows == 1
    assert Budget.check(task_id, %{max_usd_per_ticket: 0.01}) == :ok

    Usage.append(%{
      run_id: "run_rated",
      task_id: task_id,
      source: "worker",
      provider: "openrouter",
      model_id: "claude-sonnet-4-20250514",
      prompt_tokens: 1_000_000,
      completion_tokens: 0,
      estimated: true
    })

    assert {:error, :budget_exceeded, %{scope: :ticket, spent: 3.0, cap: 3.0}} =
             Budget.check(task_id, %{max_usd_per_ticket: 3.0})
  end

  test "unset caps always ok" do
    System.delete_env("SVARM_BUDGET_MAX_USD_PER_TICKET")
    System.delete_env("SVARM_BUDGET_MAX_USD_PER_DAY")
    assert Budget.check("any", %{}) == :ok
    assert Budget.check("any", Budget.load_caps(nil)) == :ok
  end

  test "per-ticket cap blocks when spent >= cap" do
    task_id = "budget_ticket_1"

    Usage.append(%{
      run_id: "r1",
      task_id: task_id,
      source: "worker",
      provider: "openrouter",
      model_id: "claude-sonnet-4-20250514",
      prompt_tokens: 1_000_000,
      completion_tokens: 0,
      provider_cost_usd: 5.0,
      estimated: false
    })

    assert {:error, :budget_exceeded, %{scope: :ticket, spent: spent, cap: 5.0}} =
             Budget.check(task_id, %{max_usd_per_ticket: 5.0})

    assert spent >= 5.0
  end

  test "per-ticket under cap allows spawn" do
    task_id = "budget_ticket_2"

    Usage.append(%{
      run_id: "r2",
      task_id: task_id,
      source: "worker",
      provider: "openrouter",
      model_id: "claude-sonnet-4-20250514",
      prompt_tokens: 100,
      completion_tokens: 0,
      provider_cost_usd: 0.01,
      estimated: false
    })

    assert Budget.check(task_id, %{max_usd_per_ticket: 1.0}) == :ok
  end

  test "day cap blocks when UTC day spend >= cap" do
    Usage.append(%{
      run_id: "r_day",
      task_id: "budget_day_task",
      source: "worker",
      provider: "openrouter",
      model_id: "x",
      prompt_tokens: 0,
      completion_tokens: 0,
      provider_cost_usd: 2.0,
      estimated: false
    })

    assert {:error, :budget_exceeded, %{scope: :day}} =
             Budget.check("other_task", %{max_usd_per_day: 1.0})
  end

  test "stricter of env and workflow wins" do
    System.put_env("SVARM_BUDGET_MAX_USD_PER_TICKET", "10")
    caps = Budget.load_caps(%{"budget" => %{"max_usd_per_ticket" => "3"}})
    assert caps.max_usd_per_ticket == 3.0
  end

  test "rejects partial float strings" do
    System.put_env("SVARM_BUDGET_MAX_USD_PER_TICKET", "1.5abc")
    caps = Budget.load_caps(nil)
    refute Map.has_key?(caps, :max_usd_per_ticket)
  end

  test "estimated rate-table spend counts toward ticket cap" do
    task_id = "budget_est_1"

    # Known model in Rates; no provider_cost → estimated cost still counts
    Usage.append(%{
      run_id: "r_est",
      task_id: task_id,
      source: "worker",
      provider: "openrouter",
      model_id: "claude-sonnet-4-20250514",
      prompt_tokens: 1_000_000,
      completion_tokens: 0,
      estimated: false
    })

    summary = Svarm.Usage.task_cost_summary(task_id)
    assert summary.estimated == true
    assert summary.total_cost_usd > 0

    assert {:error, :budget_exceeded, %{scope: :ticket}} =
             Budget.check(task_id, %{max_usd_per_ticket: summary.total_cost_usd})
  end

  test "load_mode defaults to hard and rejects unknown values" do
    System.delete_env("SVARM_BUDGET_MODE")
    assert Budget.load_mode(nil) == :hard
    assert Budget.load_mode(%{"budget" => %{"mode" => "hold"}}) == :hold
    assert Budget.load_mode(%{"budget" => %{"mode" => "skip"}}) == :hard

    System.put_env("SVARM_BUDGET_MODE", "hold")
    assert Budget.load_mode(%{"budget" => %{"mode" => "hard"}}) == :hold
  end
end
