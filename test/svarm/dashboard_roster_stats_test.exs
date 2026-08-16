defmodule Svarm.DashboardRosterStatsTest do
  use ExUnit.Case, async: false

  alias Svarm.{Dashboard, Repo}
  alias Svarm.Usage.Record

  setup do
    Repo.delete_all("usage_records")
    :ok
  end

  test "24h cost joins usage to roster by task assignee and drops older rows" do
    now = DateTime.utc_now()
    insert_usage("use_in", "task_a", now, 1.25, billed: true)
    insert_usage("use_old", "task_a", DateTime.add(now, -2 * 86_400, :second), 9.0, billed: true)
    insert_usage("use_other", "task_b", now, 0.5, billed: true)

    tasks = [
      task("task_a", "demo", 0),
      task("task_b", "other", 0)
    ]

    roster =
      tasks
      |> Dashboard.agent_roster(%{}, %{})
      |> Map.new(&{&1.key, &1})

    demo = roster["demo"]
    assert demo.window_cost_usd == 1.25
    assert demo.window_cost_estimated == false
    assert demo.window_record_count == 1
    assert demo.reliability == nil

    other = roster["other"]
    assert other.window_cost_usd == 0.5
    assert other.window_record_count == 1
    assert other.reliability == nil
  end

  test "estimated flag when any contributing row is unbilled" do
    insert_usage("use_est", "task_e", DateTime.utc_now(), 0.0, billed: false)

    roster =
      [task("task_e", "demo", 0)]
      |> Dashboard.agent_roster(%{}, %{})
      |> Map.new(&{&1.key, &1})

    demo = roster["demo"]
    assert demo.window_cost_estimated == true
    assert demo.window_record_count == 1
  end

  test "reliability is n/a when all attempts are zero" do
    roster =
      [task("t1", "demo", 0), task("t2", "demo", 0)]
      |> Dashboard.agent_roster(%{}, %{})
      |> Map.new(&{&1.key, &1})

    assert roster["demo"].reliability == nil
  end

  test "reliability is retried/total when any assigned task has attempts > 0" do
    roster =
      [task("t1", "demo", 0), task("t2", "demo", 1), task("t3", "demo", 2)]
      |> Dashboard.agent_roster(%{}, %{})
      |> Map.new(&{&1.key, &1})

    assert roster["demo"].reliability == %{retried: 2, total: 3}
  end

  defp task(id, assignee, attempts) do
    %{id: id, title: id, assignee: assignee, status: "done", attempts: attempts}
  end

  defp insert_usage(id, task_id, inserted_at, billed, opts) do
    billed? = Keyword.get(opts, :billed, true)

    Repo.insert!(%Record{
      id: id,
      run_id: "run_#{id}",
      task_id: task_id,
      source: "worker",
      provider: "openrouter",
      model_id: "unknown-model",
      prompt_tokens: 0,
      completion_tokens: 0,
      estimated: not billed?,
      provider_cost_usd: if(billed?, do: billed, else: nil),
      recorded_at: 0,
      inserted_at: inserted_at
    })
  end
end
