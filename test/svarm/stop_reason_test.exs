defmodule Svarm.StopReasonTest do
  use ExUnit.Case, async: true

  alias Svarm.{Board, StopReason}

  test "for_status covers every status in the reason table" do
    assert StopReason.for_status("review") == :review
    assert StopReason.for_status("failed") == :failed
    assert StopReason.for_status("blocked") == :blocked
    assert StopReason.for_status("no_change_needed") == :no_change_needed
  end

  test "statuses that do not stop for a human have no reason" do
    for status <- ["done", "todo", "in_progress", "pending_approval", ""] do
      assert StopReason.for_status(status) == nil
    end

    assert StopReason.for_status(nil) == nil
    assert StopReason.for_status(:review) == nil
  end

  test "text names every stop reason the ticket can report" do
    assert StopReason.text(:review) == "Needs review"
    assert StopReason.text(:failed) == "Failed"
    assert StopReason.text(:blocked) == "Blocked"
    assert StopReason.text(:no_change_needed) == "No change needed"
  end

  test "unknown reasons have no text" do
    assert StopReason.text(:running) == nil
    assert StopReason.text(:approval) == nil
    assert StopReason.text(nil) == nil
  end

  test "a board chip and the tracker comment read the same text" do
    for status <- ["review", "failed", "blocked", "no_change_needed"] do
      reason = StopReason.for_status(status)
      assert Board.wait_reason_label(reason) == StopReason.text(reason)
    end
  end
end
