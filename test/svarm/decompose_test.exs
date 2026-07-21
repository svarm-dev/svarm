defmodule Svarm.DecomposeTest do
  use ExUnit.Case, async: true

  alias Svarm.Decompose

  test "mock mode returns deterministic tasks without calling an LLM" do
    {:ok, %{tasks: tasks, goal: goal}} =
      Decompose.run(%{goal: "ship feature X", research: "notes"}, mock: true)

    assert goal == "ship feature X"
    assert match?([_, _, _], tasks)
    assert Enum.all?(tasks, &is_map/1)
    assert Enum.at(tasks, 0).type == "research"
    assert String.contains?(Enum.at(tasks, 0).title, "ship feature X")
    assert ["demo_research", "demo_code", "demo_docs"] == Enum.map(tasks, & &1.assignee)
  end
end
