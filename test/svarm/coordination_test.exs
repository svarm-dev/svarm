defmodule Svarm.CoordinationTest do
  use ExUnit.Case, async: false

  alias Svarm.Coordination
  alias Svarm.Repo

  setup do
    Repo.delete_all(Coordination)
    :ok
  end

  test "get returns nil when missing" do
    assert Coordination.get("missing") == nil
  end

  test "get_many returns map keyed by task_id" do
    {:ok, _} = Coordination.upsert("a", %{ci_circuit_open: true})

    {:ok, _} =
      Coordination.upsert("b", %{
        pr_url: "https://github.com/o/r/pull/1",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 1
      })

    map = Coordination.get_many(["a", "b", "missing"])
    assert Map.has_key?(map, "a")
    assert Map.has_key?(map, "b")
    refute Map.has_key?(map, "missing")
    assert map["a"].ci_circuit_open == true
  end

  test "upsert inserts and updates fields" do
    assert {:ok, row} =
             Coordination.upsert("task_1", %{
               pr_url: "https://github.com/o/r/pull/12",
               pr_owner: "o",
               pr_repo: "r",
               pr_number: 12
             })

    assert row.task_id == "task_1"
    assert row.pr_number == 12
    assert row.ci_resume_count == 0
    assert row.ci_circuit_open == false

    assert {:ok, row2} = Coordination.upsert("task_1", %{ci_resume_count: 2})
    assert row2.ci_resume_count == 2
    assert row2.pr_number == 12
    assert row2.attempts == 0

    assert {:ok, row3} = Coordination.upsert("task_1", %{attempts: 4})
    assert row3.attempts == 4
    assert row3.pr_number == 12

    assert {:error, changeset} = Coordination.upsert("task_1", %{attempts: -1})
    assert changeset.errors[:attempts]
    assert Coordination.get("task_1").attempts == 4
  end

  test "upsert stores mid-run wait fields" do
    payload = %{"prompt" => "Which one?", "method" => "confirm", "request_id" => "q"}

    assert {:ok, row} =
             Coordination.upsert("task_wait", %{
               wait_reason: "agent_question",
               pending_question: payload
             })

    assert row.wait_reason == "agent_question"
    assert row.pending_question["prompt"] == "Which one?"

    assert {:ok, cleared} =
             Coordination.upsert("task_wait", %{wait_reason: nil, pending_question: nil})

    assert cleared.wait_reason == nil
    assert cleared.pending_question == nil
  end

  test "record_pr from URL fills owner/repo/number" do
    assert {:ok, row} =
             Coordination.record_pr("task_pr", "https://github.com/acme/app/pull/99")

    assert row.pr_owner == "acme"
    assert row.pr_repo == "app"
    assert row.pr_number == 99
    assert row.pr_url == "https://github.com/acme/app/pull/99"
  end

  test "record_pr rejects invalid URL" do
    assert {:error, :invalid_pr} = Coordination.record_pr("task_x", "not-a-url")
  end

  test "record_pr rejects owner/repo mismatch vs tracker allowlist" do
    assert {:error, :repo_mismatch} =
             Coordination.record_pr("task_mm", "https://github.com/evil/other/pull/1",
               owner: "acme",
               repo: "app"
             )

    assert {:ok, row} =
             Coordination.record_pr("task_ok", "https://github.com/acme/app/pull/9",
               owner: "acme",
               repo: "app"
             )

    assert row.pr_number == 9
  end

  test "allowed_repo?/2 is case-insensitive when allowlisted" do
    assert Coordination.allowed_repo?(%{pr_owner: "AcMe", pr_repo: "App"},
             owner: "acme",
             repo: "app"
           )

    refute Coordination.allowed_repo?(%{pr_owner: "other", pr_repo: "app"},
             owner: "acme",
             repo: "app"
           )
  end

  test "extract_pr_url ignores changelog citations and keeps the PR this run opened" do
    log = """
    - **OpenCode** ([#231](https://github.com/svarm-dev/svarm/issues/231), [#234](https://github.com/svarm-dev/svarm/pull/234)):
    https://github.com/svarm-dev/svarm/pull/267
    **PR:** https://github.com/svarm-dev/svarm/pull/267 (branch `svarm/264`, base `main`, body includes `Closes #264`)
    """

    assert Coordination.extract_pr_url(log, source_id: "264", owner: "svarm-dev", repo: "svarm") ==
             "https://github.com/svarm-dev/svarm/pull/267"
  end

  test "extract_pr_url returns nil when the log only quotes older PRs" do
    log =
      "see [#234](https://github.com/svarm-dev/svarm/pull/234) and https://github.com/o/r/pull/124 in a sentence"

    assert Coordination.extract_pr_url(log, source_id: "264") == nil
    assert Coordination.extract_pr_url("no pr here") == nil
    assert Coordination.extract_pr_url(nil) == nil
  end

  test "extract_pr_url prefers a line that names this ticket over a later bare URL" do
    log = """
    **PR:** https://github.com/o/r/pull/267 (Closes #264)
    https://github.com/o/r/pull/234
    """

    assert Coordination.extract_pr_url(log, source_id: "264") ==
             "https://github.com/o/r/pull/267"
  end

  test "extract_pr_url keeps the last bare URL when the ticket is not named" do
    log = """
    Opened PR at https://github.com/o/r/pull/3
    https://github.com/o/r/pull/1
    https://github.com/o/r/pull/2
    """

    assert Coordination.extract_pr_url(log) == "https://github.com/o/r/pull/2"
  end

  test "extract_pr_url accepts a branch token for this ticket" do
    log = "pushed https://github.com/o/r/pull/8 on svarm/264"

    assert Coordination.extract_pr_url(log, source_id: 264) ==
             "https://github.com/o/r/pull/8"
  end

  test "extract_pr_url does not treat svarm/2640 as ticket 264" do
    log = "see https://github.com/o/r/pull/9 on svarm/2640"

    assert Coordination.extract_pr_url(log, source_id: "264") == nil
  end

  test "extract_pr_url drops URLs outside the tracker repo" do
    log = """
    https://github.com/evil/other/pull/9
    https://github.com/acme/app/pull/3
    """

    assert Coordination.extract_pr_url(log, owner: "acme", repo: "app") ==
             "https://github.com/acme/app/pull/3"
  end

  test "list_with_pr skips circuit-open by default" do
    {:ok, _} =
      Coordination.record_pr("open_pr", "https://github.com/o/r/pull/1")

    {:ok, _} =
      Coordination.upsert("closed_pr", %{
        pr_url: "https://github.com/o/r/pull/2",
        pr_owner: "o",
        pr_repo: "r",
        pr_number: 2,
        ci_circuit_open: true
      })

    ids = Coordination.list_with_pr() |> Enum.map(& &1.task_id)
    assert "open_pr" in ids
    refute "closed_pr" in ids
  end

  test "list_with_pr can restrict to task_ids" do
    {:ok, _} = Coordination.record_pr("keep_pr", "https://github.com/o/r/pull/1")
    {:ok, _} = Coordination.record_pr("skip_pr", "https://github.com/o/r/pull/2")

    ids = Coordination.list_with_pr(task_ids: ["keep_pr"]) |> Enum.map(& &1.task_id)
    assert ids == ["keep_pr"]
    assert Coordination.list_with_pr(task_ids: []) == []
  end

  test "list_with_pr limit nil returns all matching rows" do
    for i <- 1..3 do
      {:ok, _} = Coordination.record_pr("all_pr_#{i}", "https://github.com/o/r/pull/#{i}")
    end

    ids = Coordination.list_with_pr(limit: nil) |> Enum.map(& &1.task_id)
    assert Enum.sort(ids) == ["all_pr_1", "all_pr_2", "all_pr_3"]
  end

  test "circuit_open?/1" do
    refute Coordination.circuit_open?("none")

    {:ok, _} = Coordination.upsert("c1", %{ci_circuit_open: true})
    assert Coordination.circuit_open?("c1")
  end
end
