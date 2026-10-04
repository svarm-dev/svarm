defmodule Svarm.Workflow.RenderFollowUpTest do
  use ExUnit.Case, async: false

  alias Svarm.Workflow.Render

  test "render_prompt includes the follow-up block once when queued" do
    task = %{
      id: "follow_up_1",
      title: "T",
      body: "B",
      status: "todo",
      follow_up: "also fix the tests"
    }

    assert {:ok, prompt} = Render.render_prompt(task, nil)
    assert prompt =~ "Operator follow-up for this run:"
    assert prompt =~ "also fix the tests"

    # Exactly once — a follow-up is consumed by the first spawn, never repeated.
    occurrences =
      prompt
      |> String.split("Operator follow-up for this run:")
      |> length()

    assert occurrences == 2
  end

  test "render_prompt without follow_up has no follow-up block" do
    assert {:ok, prompt} =
             Render.render_prompt(
               %{id: "no_follow_up", title: "T", body: "B", status: "todo"},
               nil
             )

    refute prompt =~ "Operator follow-up"
  end

  test "blank or absent follow_up field renders nothing" do
    assert {:ok, prompt} =
             Render.render_prompt(
               %{id: "blank_follow_up", title: "T", body: "B", status: "todo", follow_up: "  "},
               nil
             )

    refute prompt =~ "Operator follow-up"
  end

  test "no new placeholder is required — append-only block" do
    assert Render.validate("do {{issue.title}}") == :ok
  end
end
