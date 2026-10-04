defmodule Svarm.BoardReviewSortTest do
  use ExUnit.Case, async: false

  alias Svarm.Board

  defp review_card(overrides) do
    Map.merge(
      %{
        id: "t-#{System.unique_integer([:positive])}",
        title: "review card",
        type: "code",
        assignee: "demo",
        status: "review",
        priority: 0,
        attempts: 0,
        created_at: 1_700_000_000,
        ci_conclusion: nil,
        ci_summary: nil,
        ci_checked_at: nil,
        pr_url: nil
      },
      overrides
    )
  end

  defp ids(cards), do: Enum.map(cards, & &1.id)

  test "empty review column stays empty" do
    assert Board.review_sorted([]) == []
    assert [] = Enum.map(Board.review_sorted([]), & &1.id)
  end

  test "CI fail sorts before pending, which sorts before pass/unknown/na" do
    fail = review_card(%{id: "a-fail", ci_conclusion: "failed"})
    pending = review_card(%{id: "b-pending", ci_conclusion: "in_progress"})
    passed = review_card(%{id: "c-pass", ci_conclusion: "passed"})
    unknown = review_card(%{id: "d-unknown", ci_conclusion: "unknown"})
    # Local tracker: no coordination row → CI is `na` (same as the chip).
    local = review_card(%{id: "e-local"})

    assert ids(Board.review_sorted(Enum.shuffle([local, unknown, passed, pending, fail]))) ==
             ["a-fail", "b-pending", "c-pass", "d-unknown", "e-local"]
  end

  test "no PR sorts before has PR at the same CI level" do
    no_pr = review_card(%{id: "no-pr"})
    has_pr = review_card(%{id: "has-pr", pr_url: "https://github.com/o/r/pull/1"})

    assert ids(Board.review_sorted([has_pr, no_pr])) == ["no-pr", "has-pr"]
  end

  test "higher ticket cost sorts first" do
    cheap = review_card(%{id: "cheap"})
    pricey = review_card(%{id: "pricey"})

    costs = %{
      "pricey" => %{total_cost_usd: 12.5, record_count: 3, estimated: false},
      "cheap" => %{total_cost_usd: 0.4, record_count: 2, estimated: true}
    }

    assert ids(Board.review_sorted([cheap, pricey], costs)) == ["pricey", "cheap"]
  end

  test "older created_at sorts first when cost ties" do
    newer = review_card(%{id: "newer", created_at: 1_700_000_500})
    older = review_card(%{id: "older", created_at: 1_600_000_000})

    assert ids(Board.review_sorted([newer, older])) == ["older", "newer"]
  end

  test "task id is the final tiebreak" do
    z = review_card(%{id: "t-z"})
    a = review_card(%{id: "t-a"})

    assert ids(Board.review_sorted([z, a])) == ["t-a", "t-z"]
  end

  test "run-meta pr_url counts as has PR for the sort (same source as glance chip)" do
    no_pr = review_card(%{id: "no-pr"})
    pr_meta = review_card(%{id: "pr-meta"})

    metas = %{"pr-meta" => %{pr_url: "https://github.com/o/r/pull/9"}}

    assert ids(Board.review_sorted([pr_meta, no_pr], %{}, metas)) == ["no-pr", "pr-meta"]
  end

  test "full ladder: fail → pending → no-PR cost → no-PR cheap → has PR → older → id" do
    fail = review_card(%{id: "1-fail", ci_conclusion: "failed"})
    pending = review_card(%{id: "2-pending", ci_conclusion: "in_progress"})
    no_pr_pricey = review_card(%{id: "3-no-pr-pricey"})
    no_pr_cheap = review_card(%{id: "4-no-pr-cheap"})

    has_pr = review_card(%{id: "5-has-pr", pr_url: "https://github.com/o/r/pull/7"})

    older =
      review_card(%{
        id: "6-older",
        pr_url: "https://github.com/o/r/pull/8",
        created_at: 1_600_000_000
      })

    newest =
      review_card(%{
        id: "7-newest",
        pr_url: "https://github.com/o/r/pull/9",
        created_at: 1_800_000_000
      })

    costs = %{
      "3-no-pr-pricey" => %{total_cost_usd: 42.0, record_count: 5, estimated: false},
      "4-no-pr-cheap" => %{total_cost_usd: 0.5, record_count: 1, estimated: true}
    }

    cards = Enum.shuffle([newest, fail, has_pr, no_pr_cheap, pending, older, no_pr_pricey])

    assert ids(Board.review_sorted(cards, costs)) == [
             "1-fail",
             "2-pending",
             "3-no-pr-pricey",
             "4-no-pr-cheap",
             "6-older",
             "5-has-pr",
             "7-newest"
           ]
  end
end
