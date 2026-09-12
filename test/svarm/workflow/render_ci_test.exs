defmodule Svarm.Workflow.RenderCiTest do
  use ExUnit.Case, async: false

  alias Svarm.{Coordination, Repo, Workflow}
  alias Svarm.Workflow.Render

  setup do
    Repo.delete_all(Coordination)
    :ok
  end

  # Temp workflow whose front matter configures review.checklist. Used to
  # prove render_prompt/2 appends labels when the Store holds a checklist.
  defp checklist_workflow do
    {:ok, base} = Workflow.load(Path.join(:code.priv_dir(:svarm), "workflow_template.md"))

    config =
      Map.put(base.config, "review", %{
        "checklist" => ["pr", %{"id" => "docs", "label" => "Docs link"}]
      })

    %{base | config: config}
  end

  test "checklist_block is nil without review.checklist" do
    assert Render.checklist_block(%Workflow{config: %{}}) == nil
    assert Render.checklist_block(%{}) == nil
  end

  test "checklist_block renders item labels only (informational)" do
    wf = %Workflow{
      config: %{
        "review" => %{
          "checklist" => ["pr", %{"id" => "docs", "label" => "Docs link"}]
        }
      },
      prompt_template: "Do {{issue.id}}",
      path: "x"
    }

    block = Render.checklist_block(wf)
    assert block =~ "Proof-of-work checklist"
    assert block =~ "- PR"
    assert block =~ "- Docs link"
    refute block =~ "{{issue"
  end

  test "render_prompt appends checklist labels when the WORKFLOW configures one" do
    original = :sys.get_state(Svarm.Workflow.Store)

    :sys.replace_state(Svarm.Workflow.Store, fn state ->
      %{state | workflow: checklist_workflow()}
    end)

    try do
      assert {:ok, prompt} =
               Render.render_prompt(
                 %{id: "render_checklist_1", title: "T", body: "B", status: "todo"},
                 nil
               )

      assert prompt =~ "Proof-of-work checklist"
      assert prompt =~ "- PR"
      assert prompt =~ "- Docs link"
    after
      :sys.replace_state(Svarm.Workflow.Store, fn state ->
        %{state | workflow: original.workflow}
      end)
    end
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
