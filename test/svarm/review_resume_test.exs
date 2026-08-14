defmodule Svarm.ReviewResumeTest do
  use ExUnit.Case, async: true

  alias Svarm.ReviewResume

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
end
