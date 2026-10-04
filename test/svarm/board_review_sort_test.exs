defmodule Svarm.BoardReviewSortTest do
  use ExUnit.Case, async: false

  alias Svarm.Board

  test "sort_review_tasks orders fail, pending, no PR, cost, age, then id" do
    tasks = [
      %{id: "age_zero", status: "review", pr_url: "https://example/pr/z", created_at: 0},
      %{id: "id_b", status: "review", pr_url: "https://example/pr/b", created_at: 300},
      %{
        id: "newer",
        status: "review",
        pr_url: "https://example/pr/n",
        ci_conclusion: "passed",
        created_at: 200
      },
      %{id: "age_nil", status: "review", pr_url: "https://example/pr/n", created_at: nil},
      %{id: "older", status: "review", ci_conclusion: "unknown", created_at: 100},
      %{
        id: "costly",
        status: "review",
        pr_url: "https://example/pr/c",
        ci_conclusion: "passed",
        created_at: 900
      },
      %{id: "no_pr", status: "review", pr_url: nil, created_at: 1},
      %{
        id: "pending",
        status: "review",
        pr_url: nil,
        ci_conclusion: "in_progress",
        created_at: 1
      },
      %{id: "id_a", status: "review", pr_url: "https://example/pr/a", created_at: 300},
      %{
        id: "fail",
        status: "review",
        pr_url: "https://example/pr/f",
        ci_conclusion: "failure",
        created_at: 800
      }
    ]

    ids =
      tasks
      |> Board.sort_review_tasks(
        costs: %{
          "fail" => %{total_cost_usd: 0.01},
          "pending" => %{total_cost_usd: 99},
          "no_pr" => %{total_cost_usd: 99},
          "costly" => %{total_cost_usd: 20}
        },
        run_meta: %{"older" => %{pr_url: "https://example/pr/8"}}
      )
      |> Enum.map(& &1.id)

    assert ids == [
             "fail",
             "pending",
             "no_pr",
             "costly",
             "older",
             "newer",
             "id_a",
             "id_b",
             "age_nil",
             "age_zero"
           ]
  end

  test "local na CI skips fail and pending classes" do
    tasks = [
      %{
        id: "na_pr",
        status: "review",
        pr_url: "https://example/pr/1",
        ci_conclusion: nil,
        created_at: 50
      },
      %{id: "na_none", status: "review", pr_url: nil, ci_conclusion: nil, created_at: 10},
      %{
        id: "pass_pr",
        status: "review",
        pr_url: "https://example/pr/2",
        ci_conclusion: "passed",
        created_at: 10
      },
      %{
        id: "unknown_pr",
        status: "review",
        pr_url: "https://example/pr/3",
        ci_conclusion: "unknown",
        created_at: 10
      }
    ]

    ids =
      Board.sort_review_tasks(tasks, costs: %{"na_pr" => %{total_cost_usd: 3}})
      |> Enum.map(& &1.id)

    assert ids == ["na_none", "na_pr", "pass_pr", "unknown_pr"]
  end

  test "sort_review_tasks uses preloaded PR and run meta only" do
    tasks = [
      %{id: "bare", status: "review", created_at: 10},
      %{id: "meta_pr", status: "review", created_at: 20}
    ]

    ids =
      Board.sort_review_tasks(tasks,
        run_meta: %{"meta_pr" => %{pr_url: "https://example/pr/9"}}
      )
      |> Enum.map(& &1.id)

    assert ids == ["bare", "meta_pr"]
  end

  test "sort_review_tasks empty list stays empty" do
    assert Board.sort_review_tasks([]) == []
    assert Board.sort_review_tasks([], costs: %{}, run_meta: %{}) == []
  end

  test "group_by_status sorts only the review bucket" do
    tasks = [
      %{id: "todo_b", status: "todo", created_at: 2, priority: 5},
      %{id: "todo_a", status: "todo", created_at: 1, priority: 0},
      %{
        id: "rev_pr",
        status: "review",
        pr_url: "https://example/pr/1",
        ci_conclusion: "passed",
        created_at: 1
      },
      %{
        id: "rev_fail",
        status: "review",
        pr_url: "https://example/pr/2",
        ci_conclusion: "failed",
        created_at: 99
      }
    ]

    grouped = Board.group_by_status(tasks, costs: %{})

    assert Enum.map(grouped["todo"], & &1.id) == ["todo_b", "todo_a"]
    assert Enum.map(grouped["review"], & &1.id) == ["rev_fail", "rev_pr"]
    assert grouped["done"] == []
  end
end
