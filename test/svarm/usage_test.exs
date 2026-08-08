defmodule Svarm.UsageTest do
  use ExUnit.Case, async: false

  alias Svarm.Repo
  alias Svarm.Usage

  setup do
    # Clean the usage_records table before each test
    Repo.delete_all("usage_records")
    :ok
  end

  describe "append/1 and for_task/1" do
    test "appends a record and retrieves it by task_id" do
      record =
        Usage.append(%{
          run_id: "run_test1",
          task_id: "task_test1",
          tenant: "test-goal",
          source: "worker",
          provider: "openrouter",
          model_id: "claude-sonnet-4-20250514",
          prompt_tokens: 1000,
          completion_tokens: 500,
          estimated: false
        })

      assert record.id =~ "use_"
      assert record.task_id == "task_test1"
      assert record.source == "worker"

      records = Usage.for_task("task_test1")
      assert Enum.count(records) == 1
      assert hd(records).id == record.id
    end

    test "multiple records for the same task" do
      Usage.append(%{
        run_id: "run_a",
        task_id: "task_multi",
        source: "decompose",
        provider: "openrouter",
        model_id: "gpt-5.1",
        prompt_tokens: 500,
        completion_tokens: 200,
        estimated: false
      })

      Usage.append(%{
        run_id: "run_b",
        task_id: "task_multi",
        source: "worker",
        provider: "openrouter",
        model_id: "claude-sonnet-4-20250514",
        prompt_tokens: 2000,
        completion_tokens: 800,
        estimated: false
      })

      records = Usage.for_task("task_multi")
      assert Enum.count(records) == 2
    end
  end

  describe "cost_usd/4" do
    test "calculates cost for known model" do
      assert {:ok, cost} =
               Usage.cost_usd("openrouter", "claude-sonnet-4-20250514", 1_000_000, 1_000_000)

      assert cost == 18.0
    end

    test "returns error for unknown model" do
      assert {:error, :unknown_model} = Usage.cost_usd("openrouter", "no-such-model", 1000, 1000)
    end

    test "handles nil token counts" do
      assert {:ok, cost} = Usage.cost_usd("openrouter", "gpt-4.1", nil, nil)
      assert cost == 0.0
    end
  end

  describe "task_cost/1" do
    test "aggregates multiple records for a task" do
      task_id = "task_cost_test"

      Usage.append(%{
        run_id: "r1",
        task_id: task_id,
        source: "decompose",
        provider: "openrouter",
        model_id: "gpt-5.1",
        prompt_tokens: 1_000_000,
        completion_tokens: 0,
        estimated: false
      })

      Usage.append(%{
        run_id: "r2",
        task_id: task_id,
        source: "worker",
        provider: "openrouter",
        model_id: "claude-sonnet-4-20250514",
        prompt_tokens: 0,
        completion_tokens: 1_000_000,
        estimated: false
      })

      report = Usage.task_cost(task_id)
      assert report.task_id == task_id
      assert report.total_cost_usd == 16.75
      # Rate-table-only rows are approximate
      assert report.estimated == true
      assert report.record_count == 2
      assert map_size(report.breakdown) == 2
    end

    test "prefers provider_cost_usd over rate table" do
      task_id = "task_provider_cost"

      Usage.append(%{
        run_id: "r_pc",
        task_id: task_id,
        source: "worker",
        provider: "openrouter",
        model_id: "deepseek/deepseek-v4-flash",
        prompt_tokens: 90_000,
        completion_tokens: 6_200,
        provider_cost_usd: 0.0148,
        estimated: false
      })

      report = Usage.task_cost(task_id)
      assert report.total_cost_usd == 0.0148
      assert report.estimated == false
    end

    test "rate-table-only is estimated even when estimated flag is false" do
      task_id = "task_rate_est"

      Usage.append(%{
        run_id: "r_est",
        task_id: task_id,
        source: "worker",
        provider: "openrouter",
        model_id: "claude-sonnet-4-20250514",
        prompt_tokens: 1000,
        completion_tokens: 100,
        estimated: false
      })

      report = Usage.task_cost(task_id)
      assert report.estimated == true
    end

    test "appends wall-clock inserted_at" do
      record =
        Usage.append(%{
          run_id: "r_ts",
          task_id: "task_ts",
          source: "worker",
          provider: "openrouter",
          model_id: "claude-sonnet-4-20250514",
          prompt_tokens: 10,
          completion_tokens: 5
        })

      assert %DateTime{} = record.inserted_at
    end
  end

  describe "task_cost_summaries/1" do
    test "batches multiple tasks in one map" do
      Usage.append(%{
        run_id: "r_batch_a",
        task_id: "task_a",
        source: "worker",
        provider: "openrouter",
        model_id: "gpt-5.1",
        prompt_tokens: 1_000_000,
        completion_tokens: 0,
        estimated: false
      })

      Usage.append(%{
        run_id: "r_batch_b",
        task_id: "task_b",
        source: "worker",
        provider: "openrouter",
        model_id: "claude-sonnet-4-20250514",
        prompt_tokens: 0,
        completion_tokens: 1_000_000,
        estimated: false
      })

      summaries = Usage.task_cost_summaries(["task_a", "task_b", "task_missing"])

      assert map_size(summaries) == 2
      assert summaries["task_a"].total_cost_usd == 1.75
      assert summaries["task_a"].estimated == true
      assert summaries["task_b"].total_cost_usd == 15.0
      assert summaries["task_b"].estimated == true
      refute Map.has_key?(summaries, "task_missing")
    end

    test "empty task list returns empty map without error" do
      assert Usage.task_cost_summaries([]) == %{}
    end

    test "provider_cost_usd remains exact in batch summaries" do
      Usage.append(%{
        run_id: "r_batch_pc",
        task_id: "task_pc_batch",
        source: "worker",
        provider: "openrouter",
        model_id: "deepseek/deepseek-v4-flash",
        prompt_tokens: 90_000,
        completion_tokens: 6_200,
        provider_cost_usd: 0.0148,
        estimated: false
      })

      summary = Usage.task_cost_summary("task_pc_batch")
      assert summary.total_cost_usd == 0.0148
      assert summary.estimated == false
    end
  end

  describe "session_cost_summary/0" do
    test "aggregates cost and tokens without requiring list_all" do
      Usage.append(%{
        run_id: "r_sess_1",
        task_id: "task_sess_1",
        source: "worker",
        provider: "openrouter",
        model_id: "gpt-5.1",
        prompt_tokens: 1_000_000,
        completion_tokens: 0,
        estimated: false
      })

      Usage.append(%{
        run_id: "r_sess_2",
        task_id: "task_sess_2",
        source: "worker",
        provider: "openrouter",
        model_id: "claude-sonnet-4-20250514",
        prompt_tokens: 0,
        completion_tokens: 1_000_000,
        provider_cost_usd: 0.5,
        estimated: false
      })

      summary = Usage.session_cost_summary()

      # gpt-5.1 rate: 1.75 + provider bill 0.5
      assert summary.total_cost_usd == 2.25
      assert summary.prompt_tokens == 1_000_000
      assert summary.completion_tokens == 1_000_000
      assert summary.record_count == 2
      # rate-table row makes the session estimated
      assert summary.estimated == true

      totals = Usage.session_totals()
      assert totals.prompt_tokens == summary.prompt_tokens
      assert totals.completion_tokens == summary.completion_tokens
      assert totals.record_count == summary.record_count
    end

    test "empty ledger returns zeroed summary" do
      summary = Usage.session_cost_summary()

      assert summary.total_cost_usd == 0.0
      assert summary.record_count == 0
      assert summary.prompt_tokens == 0
      assert summary.completion_tokens == 0
      assert summary.estimated == false
    end

    test "all provider-billed rows are not estimated" do
      Usage.append(%{
        run_id: "r_exact",
        task_id: "task_exact",
        source: "worker",
        provider: "openrouter",
        model_id: "unknown-model",
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: 1.23,
        estimated: false
      })

      summary = Usage.session_cost_summary()
      assert summary.total_cost_usd == 1.23
      assert summary.estimated == false
    end
  end
end
