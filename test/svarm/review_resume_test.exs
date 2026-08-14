defmodule Svarm.ReviewResumeTest do
  use ExUnit.Case, async: false

  alias Svarm.ReviewResume

  setup do
    prev_enabled = System.get_env("SVARM_REVIEW_RESUME_ENABLED")

    on_exit(fn ->
      restore_env("SVARM_REVIEW_RESUME_ENABLED", prev_enabled)
    end)

    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  @summary_requested %{
    decision: :changes_requested,
    head_sha: "sha1",
    reviewer_logins: ["alice"],
    summary: "Changes requested by alice"
  }

  @summary_none %{
    decision: :none,
    head_sha: "sha1",
    reviewer_logins: [],
    summary: "no changes requested"
  }

  test "nil summary is noop" do
    assert ReviewResume.evaluate(%{review_decision: nil}, nil) == :noop
  end

  test "records new changes requested" do
    coord = %{review_decision: nil, review_last_head_sha: nil}
    assert ReviewResume.evaluate(coord, @summary_requested) == :record
  end

  test "noop when same sha already recorded as changes requested" do
    coord = %{review_decision: "changes_requested", review_last_head_sha: "sha1"}
    assert ReviewResume.evaluate(coord, @summary_requested) == :noop
  end

  test "records again when head sha moved" do
    coord = %{review_decision: "changes_requested", review_last_head_sha: "old"}
    assert ReviewResume.evaluate(coord, @summary_requested) == :record
  end

  test "clears when previously requested and now none" do
    coord = %{review_decision: "changes_requested", review_last_head_sha: "sha1"}
    assert ReviewResume.evaluate(coord, @summary_none) == :clear
  end

  test "noop when never requested and still none" do
    coord = %{review_decision: nil, review_last_head_sha: nil}
    assert ReviewResume.evaluate(coord, @summary_none) == :noop
  end

  test "context_summary includes reviewers and sha" do
    text = ReviewResume.context_summary(@summary_requested)
    assert text =~ "Review feedback"
    assert text =~ "alice"
    assert text =~ "sha1"
    assert text =~ "Do not merge"
  end

  @spawn_caps %{enabled: true, max_attempts: 3}

  test "spawn_evaluate disabled is noop" do
    coord = %{review_decision: nil, ci_resume_count: 0, ci_circuit_open: false}

    assert ReviewResume.spawn_evaluate(coord, :record, %{@spawn_caps | enabled: false}) ==
             :noop
  end

  test "spawn_evaluate ignores non-record decisions" do
    coord = %{review_decision: nil, ci_resume_count: 0, ci_circuit_open: false}
    assert ReviewResume.spawn_evaluate(coord, :noop, @spawn_caps) == :noop
    assert ReviewResume.spawn_evaluate(coord, :clear, @spawn_caps) == :noop
  end

  test "spawn_evaluate resumes on first transition into changes requested" do
    coord = %{review_decision: nil, ci_resume_count: 0, ci_circuit_open: false}
    assert ReviewResume.spawn_evaluate(coord, :record, @spawn_caps) == :resume

    coord_none = %{review_decision: "none", ci_resume_count: 1, ci_circuit_open: false}
    assert ReviewResume.spawn_evaluate(coord_none, :record, @spawn_caps) == :resume
  end

  test "spawn_evaluate noops when already in the same episode" do
    coord = %{
      review_decision: "changes_requested",
      ci_resume_count: 0,
      ci_circuit_open: false
    }

    assert ReviewResume.spawn_evaluate(coord, :record, @spawn_caps) == :noop
  end

  test "spawn_evaluate noops when circuit already open" do
    coord = %{review_decision: nil, ci_resume_count: 0, ci_circuit_open: true}
    assert ReviewResume.spawn_evaluate(coord, :record, @spawn_caps) == :noop
  end

  test "spawn_evaluate opens circuit when shared count is at the cap" do
    coord = %{review_decision: nil, ci_resume_count: 3, ci_circuit_open: false}

    assert ReviewResume.spawn_evaluate(coord, :record, @spawn_caps) == :circuit_open
  end

  test "load_caps defaults disabled" do
    System.delete_env("SVARM_REVIEW_RESUME_ENABLED")
    assert ReviewResume.load_caps(nil).enabled == false
  end

  test "load_caps from workflow and env" do
    System.delete_env("SVARM_REVIEW_RESUME_ENABLED")
    assert ReviewResume.load_caps(%{"review_resume" => %{"enabled" => true}}).enabled == true

    System.put_env("SVARM_REVIEW_RESUME_ENABLED", "true")
    assert ReviewResume.load_caps(%{"review_resume" => %{"enabled" => false}}).enabled == true

    System.delete_env("SVARM_REVIEW_RESUME_ENABLED")
  end
end
