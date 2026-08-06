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
end
