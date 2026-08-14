defmodule Svarm.Workflow.RenderCiTest do
  use ExUnit.Case, async: false

  alias Svarm.{Coordination, Repo}
  alias Svarm.Workflow.Render

  setup do
    Repo.delete_all(Coordination)
    :ok
  end

  test "render_prompt appends ci_context_summary when present" do
    task_id = "render_ci_1"

    {:ok, _} =
      Coordination.upsert(task_id, %{
        ci_context_summary: "## CI feedback\n\nCI failed: mix"
      })

    assert {:ok, prompt} =
             Render.render_prompt(%{id: task_id, title: "T", body: "B", status: "todo"}, nil)

    assert prompt =~ "CI feedback"
    assert prompt =~ "mix"
  end

  test "render_prompt without coordination has no CI block" do
    assert {:ok, prompt} =
             Render.render_prompt(%{id: "no_ci", title: "T", body: "B", status: "todo"}, nil)

    refute prompt =~ "CI feedback"
  end

  test "render_prompt appends review_context_summary when present" do
    task_id = "render_review_1"

    {:ok, _} =
      Coordination.upsert(task_id, %{
        review_context_summary: "## Review feedback (changes requested)\n\nPlease fix the test"
      })

    assert {:ok, prompt} =
             Render.render_prompt(%{id: task_id, title: "T", body: "B", status: "todo"}, nil)

    assert prompt =~ "Review feedback"
    assert prompt =~ "Please fix the test"
  end

  test "render_prompt accepts {{review_feedback}} placeholder" do
    assert Render.validate("hello {{review_feedback}}") == :ok
  end
end
