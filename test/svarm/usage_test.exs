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
      assert report.estimated == false
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
  end
end
