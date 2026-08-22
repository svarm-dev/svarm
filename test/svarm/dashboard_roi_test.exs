defmodule Svarm.DashboardRoiTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Svarm.{Coordination, Dashboard, KanbanBridge, Usage}
  alias Svarm.Repo
  alias Svarm.Usage.Record

  @github_config %{kind: :github, owner: "acme", repo: "app", api_key: "t"}

  defmodule CountingReq do
    def get(url, _opts) do
      Process.put(:github_pr_http_count, Process.get(:github_pr_http_count, 0) + 1)
      Process.put(:github_pr_http_urls, [url | Process.get(:github_pr_http_urls, [])])
      {:ok, %{status: 200, body: %{"merged" => true, "state" => "closed"}}}
    end
  end

  setup do
    KanbanBridge.delete_all_tasks()
    Repo.delete_all(Record)
    Repo.delete_all(Coordination)
    Process.delete(:github_pr_http_count)
    Process.delete(:github_pr_http_urls)
    :ok
  end

  test "roi_for_window slices by_agent from one ledger grouping" do
    done = KanbanBridge.create_task(%{title: "merged", status: "done", assignee: "demo"})
    todo = KanbanBridge.create_task(%{title: "other", status: "todo", assignee: "demo"})
    review = KanbanBridge.create_task(%{title: "review", status: "review", assignee: "demo_code"})

    idle =
      KanbanBridge.create_task(%{title: "no spend", status: "todo", assignee: "demo_docs"})

    append_billed(done.id, "run_done", 2.0)
    append_billed(todo.id, "run_todo", 0.5)
    append_billed(review.id, "run_review", 1.0)

    tasks = [done, todo, review, idle]

    {roi, group_queries} =
      with_ledger_group_queries(fn ->
        Dashboard.roi_for_window("session", tasks)
      end)

    assert [group_query] = group_queries
    assert group_query =~ "GROUP BY"
    assert group_query =~ "task_id"

    assert roi.window == "session"
    assert roi.since == nil

    overall = roi.overall
    assert overall.tasks_with_spend == 3
    assert overall.merged_tasks == 1
    assert overall.in_review_tasks == 1
    assert overall.other_tasks == 1
    assert overall.merge_rate == 0.3333
    assert overall.cost_per_merged_usd == 2.0
    assert overall.estimated == false

    by_agent = Map.new(roi.by_agent, &{&1.assignee, &1})
    assert Map.keys(by_agent) -- ["demo", "demo_code"] == []
    refute Map.has_key?(by_agent, "demo_docs")

    demo = by_agent["demo"]
    assert demo.display_name == "Demo"
    assert demo.metrics.tasks_with_spend == 2
    assert demo.metrics.merged_tasks == 1
    assert demo.metrics.other_tasks == 1
    assert demo.metrics.in_review_tasks == 0
    assert demo.metrics.merge_rate == 0.5
    assert demo.metrics.cost_per_merged_usd == 2.0
    assert demo.metrics.estimated == false

    code = by_agent["demo_code"]
    assert code.display_name == "Demo Code"
    assert code.metrics.tasks_with_spend == 1
    assert code.metrics.merged_tasks == 0
    assert code.metrics.in_review_tasks == 1
    assert code.metrics.merge_rate == 0.0
    assert code.metrics.cost_per_merged_usd == nil
    assert code.metrics.estimated == false

    names = Enum.map(roi.by_agent, & &1.display_name)
    assert names == Enum.sort(names)
  end

  test "GitHub merge flags are fetched once per unique PR per snapshot" do
    a = review_task("demo", 11)
    b = review_task("demo_code", 22)
    c = review_task("demo_docs", 11)

    {roi, group_queries} =
      with_ledger_group_queries(fn ->
        Dashboard.roi_for_window("session", [a, b, c],
          tracker_config: @github_config,
          req: CountingReq
        )
      end)

    assert [_] = group_queries
    assert Process.get(:github_pr_http_count) == 2

    urls = Process.get(:github_pr_http_urls, [])
    assert Enum.any?(urls, &String.contains?(&1, "/pulls/11"))
    assert Enum.any?(urls, &String.contains?(&1, "/pulls/22"))

    overall = roi.overall
    assert overall.tasks_with_spend == 3
    assert overall.merged_tasks == 3
    assert overall.in_review_tasks == 0
    assert overall.merge_rate == 1.0
    assert overall.estimated == true

    by_agent = Map.new(roi.by_agent, &{&1.assignee, &1})
    assert by_agent["demo"].metrics.merged_tasks == 1
    assert by_agent["demo_code"].metrics.merged_tasks == 1
    assert by_agent["demo_docs"].metrics.merged_tasks == 1
    assert by_agent["demo"].metrics.tasks_with_spend == 1
  end

  test "estimated is true when any contributing spend is unbilled, false when all billed" do
    billed = KanbanBridge.create_task(%{title: "billed", status: "done", assignee: "demo"})

    unbilled =
      KanbanBridge.create_task(%{title: "unbilled", status: "done", assignee: "demo_code"})

    append_billed(billed.id, "run_billed", 1.25)

    billed_only = Dashboard.roi_for_window("session", [billed])
    assert billed_only.overall.estimated == false
    assert billed_only.overall.cost_per_merged_usd == 1.25
    assert hd(billed_only.by_agent).metrics.estimated == false

    append_unbilled(unbilled.id, "run_unbilled")
    mixed = Dashboard.roi_for_window("session", [billed, unbilled])

    assert mixed.overall.estimated == true
    assert mixed.overall.tasks_with_spend == 2
    by_agent = Map.new(mixed.by_agent, &{&1.assignee, &1})
    assert by_agent["demo"].metrics.estimated == false
    assert by_agent["demo_code"].metrics.estimated == true
  end

  test "session includes older wall-clock rows; 24h and 7d exclude via inserted_at" do
    old = KanbanBridge.create_task(%{title: "old", status: "done", assignee: "demo"})
    mid = KanbanBridge.create_task(%{title: "mid", status: "done", assignee: "demo_code"})
    new = KanbanBridge.create_task(%{title: "new", status: "done", assignee: "demo"})

    append_billed(old.id, "run_old", 9.0)
    append_billed(mid.id, "run_mid", 2.0)
    append_billed(new.id, "run_new", 1.25)

    now = DateTime.utc_now()

    Repo.update_all(from(r in Record, where: r.run_id == "run_old"),
      set: [inserted_at: DateTime.add(now, -8 * 86_400, :second)]
    )

    Repo.update_all(from(r in Record, where: r.run_id == "run_mid"),
      set: [inserted_at: DateTime.add(now, -2 * 86_400, :second)]
    )

    tasks = [old, mid, new]

    {session, session_queries} =
      with_ledger_group_queries(fn -> Dashboard.roi_for_window("session", tasks) end)

    {seven, seven_queries} =
      with_ledger_group_queries(fn -> Dashboard.roi_for_window("7d", tasks) end)

    {day, day_queries} =
      with_ledger_group_queries(fn -> Dashboard.roi_for_window("24h", tasks) end)

    assert [_] = session_queries
    assert [_] = seven_queries
    assert [_] = day_queries

    assert session.since == nil
    assert session.overall.tasks_with_spend == 3
    assert session.overall.merged_tasks == 3
    assert session.overall.cost_per_merged_usd == Float.round((9.0 + 2.0 + 1.25) / 3, 4)
    session_agents = Map.new(session.by_agent, &{&1.assignee, &1})
    assert session_agents["demo"].metrics.tasks_with_spend == 2
    assert session_agents["demo_code"].metrics.tasks_with_spend == 1

    assert match?(%DateTime{}, seven.since)
    assert seven.overall.tasks_with_spend == 2
    assert seven.overall.merged_tasks == 2
    assert seven.overall.cost_per_merged_usd == Float.round((2.0 + 1.25) / 2, 4)
    seven_agents = Map.new(seven.by_agent, &{&1.assignee, &1})
    assert seven_agents["demo"].metrics.tasks_with_spend == 1
    assert seven_agents["demo_code"].metrics.tasks_with_spend == 1

    assert match?(%DateTime{}, day.since)
    assert day.overall.tasks_with_spend == 1
    assert day.overall.merged_tasks == 1
    assert day.overall.cost_per_merged_usd == 1.25
    day_agents = Map.new(day.by_agent, &{&1.assignee, &1})
    assert Map.keys(day_agents) == ["demo"]
    assert day_agents["demo"].metrics.tasks_with_spend == 1
    assert day_agents["demo"].metrics.cost_per_merged_usd == 1.25
  end

  defp review_task(assignee, pr_number) do
    task =
      KanbanBridge.create_task(%{
        title: "review-#{pr_number}",
        status: "review",
        assignee: assignee
      })

    append_unbilled(
      task.id,
      "run_pr_#{assignee}_#{pr_number}_#{System.unique_integer([:positive])}"
    )

    {:ok, _} =
      Coordination.record_pr(task.id, %{
        pr_owner: "acme",
        pr_repo: "app",
        pr_number: pr_number
      })

    task
  end

  defp append_billed(task_id, run_id, usd) do
    Usage.append(
      run_id: run_id,
      task_id: task_id,
      source: "agent",
      provider: "openrouter",
      model_id: "test/m",
      prompt_tokens: 0,
      completion_tokens: 0,
      estimated: false,
      provider_cost_usd: usd
    )
  end

  defp append_unbilled(task_id, run_id) do
    Usage.append(
      run_id: run_id,
      task_id: task_id,
      source: "agent",
      provider: "openrouter",
      model_id: "test/m",
      prompt_tokens: 8,
      completion_tokens: 4,
      estimated: true
    )
  end

  defp with_ledger_group_queries(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = "roi-ledger-groups-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:svarm, :repo, :query],
        fn _event, _meas, meta, _cfg ->
          if ledger_group_query?(meta) do
            send(parent, {:ledger_group_query, to_string(meta[:query])})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_group_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp ledger_group_query?(meta) do
    query = meta |> Map.get(:query) |> to_string()
    source = meta[:source]

    (source == "usage_records" or String.contains?(query, "usage_records")) and
      String.contains?(String.upcase(query), "GROUP BY") and
      String.contains?(query, "task_id")
  end

  defp drain_group_queries(acc) do
    receive do
      {:ledger_group_query, query} -> drain_group_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
