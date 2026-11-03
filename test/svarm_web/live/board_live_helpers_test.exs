defmodule SvarmWeb.BoardLiveHelpersTest do
  use ExUnit.Case, async: false

  alias Svarm.{Board, Coordination, Repo}
  alias SvarmWeb.BoardLive.Helpers

  # `Board.wait_reason/1` falls back to Coordination when a task map does not
  # preload the coordination fields, so this module shares its DB setup.
  setup do
    Repo.delete_all(Coordination)
    :ok
  end

  test "review_badge returns the wait-reason label and keeps its badge class" do
    changes_requested = %{status: "review", id: "x", review_decision: "changes_requested"}
    assert {label, class} = Helpers.review_badge(changes_requested)
    assert label == "Changes requested"
    assert label == Board.wait_reason_label(:changes_requested)
    assert class == "badge-warning"

    plain_review = %{status: "review", id: "y"}
    assert {label, class} = Helpers.review_badge(plain_review)
    assert label == "Needs review"
    assert label == Board.wait_reason_label(:review)
    assert class == "badge-warning"
  end
end
