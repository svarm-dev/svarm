defmodule Svarm.DashboardWindowTest do
  use ExUnit.Case, async: false

  alias Svarm.{Dashboard, Repo}
  alias Svarm.Usage.Record

  setup do
    Repo.delete_all("usage_records")
    :ok
  end

  test "24h and 7d windows use wall-clock inserted_at, not monotonic recorded_at" do
    now = DateTime.utc_now()
    # Looks in-window on a reset monotonic clock, but eight days old on the wall.
    insert_usage("use_old_wall", DateTime.add(now, -8 * 86_400, :second), 0, 9.0)
    insert_usage("use_mid_wall", DateTime.add(now, -2 * 86_400, :second), 0, 2.0)
    insert_usage("use_new_wall", now, 1, 1.25)

    seven = Dashboard.cost_for_window("7d")
    assert seven.total_cost_usd == 3.25
    assert seven.record_count == 2

    day = Dashboard.cost_for_window("24h")
    assert day.total_cost_usd == 1.25
    assert day.record_count == 1

    session = Dashboard.cost_for_window("session")
    assert session.total_cost_usd == 12.25
    assert session.record_count == 3
  end

  defp insert_usage(id, inserted_at, recorded_at, billed) do
    Repo.insert!(%Record{
      id: id,
      run_id: "run_#{id}",
      task_id: "task_#{id}",
      source: "worker",
      provider: "openrouter",
      model_id: "unknown-model",
      prompt_tokens: 0,
      completion_tokens: 0,
      estimated: false,
      provider_cost_usd: billed,
      recorded_at: recorded_at,
      inserted_at: inserted_at
    })
  end
end
