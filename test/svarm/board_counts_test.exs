defmodule Svarm.BoardCountsTest do
  use ExUnit.Case, async: true

  alias Svarm.Board

  test "counts_by_assignee ignores done and failed" do
    tasks = [
      %{assignee: "pi", status: "todo"},
      %{assignee: "pi", status: "in_progress"},
      %{assignee: "demo", status: "done"},
      %{assignee: nil, status: "review"}
    ]

    assert Board.counts_by_assignee(tasks) == %{"pi" => 2, "default" => 1}
  end

  test "counts_by_status groups tasks" do
    tasks = [
      %{status: "todo"},
      %{status: "todo"},
      %{status: "failed"}
    ]

    assert Board.counts_by_status(tasks) == %{"todo" => 2, "failed" => 1}
  end
end
